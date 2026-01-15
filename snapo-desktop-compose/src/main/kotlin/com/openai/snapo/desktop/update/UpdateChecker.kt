package com.openai.snapo.desktop.update

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.w3c.dom.Element
import org.xml.sax.SAXException
import java.io.IOException
import java.io.InputStream
import java.net.URI
import java.net.http.HttpClient
import java.net.http.HttpRequest
import java.net.http.HttpResponse
import java.time.Duration
import java.time.Instant
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import javax.xml.XMLConstants
import javax.xml.parsers.DocumentBuilderFactory
import javax.xml.parsers.ParserConfigurationException

internal const val AppcastUrl = "https://openai.github.io/snap-o/appcast.xml"
internal const val ReleasesUrl = "https://github.com/openai/snap-o/releases"
private const val SparkleNamespace = "http://www.andymatuschak.org/xml-namespaces/sparkle"

internal data class UpdateInfo(
    val shortVersion: String,
    val buildNumber: String?,
    val downloadUrl: String,
    val publishedAt: Instant?,
    val title: String?,
)

internal sealed interface UpdateCheckResult {
    data class UpdateAvailable(val update: UpdateInfo) : UpdateCheckResult
    data object UpToDate : UpdateCheckResult
    data class Error(val message: String) : UpdateCheckResult
}

internal class UpdateChecker(
    private val appcastUrl: String = AppcastUrl,
    private val releasesUrl: String = ReleasesUrl,
    private val httpClient: HttpClient = HttpClient.newBuilder()
        .followRedirects(HttpClient.Redirect.NORMAL)
        .connectTimeout(Duration.ofSeconds(10))
        .build(),
) {
    suspend fun check(currentVersion: String, currentBuildNumber: String?): UpdateCheckResult {
        return withContext(Dispatchers.IO) {
            runCatching { checkInternal(currentVersion, currentBuildNumber) }
                .getOrElse { throwable -> handleCheckFailure(throwable) }
        }
    }

    private fun checkInternal(currentVersion: String, currentBuildNumber: String?): UpdateCheckResult {
        val request = HttpRequest.newBuilder(URI(appcastUrl))
            .GET()
            .header("Accept", "application/rss+xml, application/xml, text/xml")
            .timeout(Duration.ofSeconds(10))
            .build()
        val response = httpClient.send(request, HttpResponse.BodyHandlers.ofInputStream())
        if (response.statusCode() !in 200..299) {
            return UpdateCheckResult.Error("Update check failed (HTTP ${response.statusCode()}).")
        }
        val items = response.body().use { parseAppcast(it) }
        val latest = pickLatest(items) ?: return UpdateCheckResult.Error("No updates found.")
        val updateInfo = UpdateInfo(
            shortVersion = latest.shortVersion
                ?: latest.titleVersion
                ?: currentVersion,
            buildNumber = latest.buildNumber,
            downloadUrl = latest.downloadUrl ?: releasesUrl,
            publishedAt = latest.publishedAt,
            title = latest.title,
        )
        return when (isNewerVersion(latest, currentVersion, currentBuildNumber)) {
            true -> UpdateCheckResult.UpdateAvailable(updateInfo)
            false -> UpdateCheckResult.UpToDate
            null -> UpdateCheckResult.Error("Unable to compare versions.")
        }
    }
}

private fun handleCheckFailure(throwable: Throwable): UpdateCheckResult {
    return when (throwable) {
        is CancellationException -> throw throwable
        is InterruptedException -> {
            Thread.currentThread().interrupt()
            UpdateCheckResult.Error(throwable.message ?: "Unable to check for updates.")
        }
        is IOException,
        is ParserConfigurationException,
        is SAXException,
        is IllegalArgumentException,
        -> UpdateCheckResult.Error(throwable.message ?: "Unable to check for updates.")
        else -> UpdateCheckResult.Error(throwable.message ?: "Unable to check for updates.")
    }
}

private data class AppcastItem(
    val title: String?,
    val titleVersion: String?,
    val shortVersion: String?,
    val buildNumber: String?,
    val downloadUrl: String?,
    val publishedAt: Instant?,
)

private fun parseAppcast(stream: InputStream): List<AppcastItem> {
    val factory = newSecureDocumentBuilderFactory()
    val document = factory.newDocumentBuilder().parse(stream)
    val nodes = document.getElementsByTagName("item")
    val items = ArrayList<AppcastItem>(nodes.length)
    for (index in 0 until nodes.length) {
        val node = nodes.item(index) as? Element ?: continue
        val title = node.firstChildText("title")
        val titleVersion = title?.substringAfterLast(' ')
        val shortVersion = node.firstChildTextNS(SparkleNamespace, "shortVersionString")
        val buildNumber = node.firstChildTextNS(SparkleNamespace, "version")
        val downloadUrl = node.firstChild("enclosure")
            ?.getAttribute("url")
            ?.takeIf { it.isNotBlank() }
        val publishedAt = node.firstChildText("pubDate")?.let(::parsePubDate)
        items += AppcastItem(
            title = title,
            titleVersion = titleVersion,
            shortVersion = shortVersion,
            buildNumber = buildNumber,
            downloadUrl = downloadUrl,
            publishedAt = publishedAt,
        )
    }
    return items
}

private fun newSecureDocumentBuilderFactory(): DocumentBuilderFactory {
    val factory = DocumentBuilderFactory.newInstance()
    factory.isNamespaceAware = true
    factory.isXIncludeAware = false
    factory.isExpandEntityReferences = false

    fun trySetFeature(name: String, value: Boolean) {
        runCatching { factory.setFeature(name, value) }
    }

    trySetFeature(XMLConstants.FEATURE_SECURE_PROCESSING, true)
    trySetFeature("http://apache.org/xml/features/disallow-doctype-decl", true)
    trySetFeature("http://xml.org/sax/features/external-general-entities", false)
    trySetFeature("http://xml.org/sax/features/external-parameter-entities", false)
    trySetFeature("http://apache.org/xml/features/nonvalidating/load-external-dtd", false)

    runCatching { factory.setAttribute(XMLConstants.ACCESS_EXTERNAL_DTD, "") }
    runCatching { factory.setAttribute(XMLConstants.ACCESS_EXTERNAL_SCHEMA, "") }

    return factory
}

private fun parsePubDate(value: String): Instant? {
    return runCatching {
        ZonedDateTime.parse(value, DateTimeFormatter.RFC_1123_DATE_TIME).toInstant()
    }.getOrNull()
}

private fun pickLatest(items: List<AppcastItem>): AppcastItem? {
    if (items.isEmpty()) return null
    return items.maxWithOrNull { left, right -> compareItems(left, right) } ?: items.first()
}

private fun compareItems(left: AppcastItem, right: AppcastItem): Int {
    compareByBuildNumber(left, right)?.let { return it }
    compareBySemver(left, right)?.let { return it }
    compareByPublishedDate(left, right)?.let { return it }
    return 0
}

private fun compareByBuildNumber(left: AppcastItem, right: AppcastItem): Int? {
    val leftBuild = parseBuildNumber(left.buildNumber)
    val rightBuild = parseBuildNumber(right.buildNumber)
    if (leftBuild == null && rightBuild == null) return null
    return (leftBuild ?: BuildNumber(0, 0)).compareTo(rightBuild ?: BuildNumber(0, 0))
}

private fun compareBySemver(left: AppcastItem, right: AppcastItem): Int? {
    val leftSemver = parseSemver(left.shortVersion ?: left.titleVersion)
    val rightSemver = parseSemver(right.shortVersion ?: right.titleVersion)
    if (leftSemver == null && rightSemver == null) return null
    return (leftSemver ?: SemVer(0, 0, 0)).compareTo(rightSemver ?: SemVer(0, 0, 0))
}

private fun compareByPublishedDate(left: AppcastItem, right: AppcastItem): Int? {
    val leftDate = left.publishedAt
    val rightDate = right.publishedAt
    if (leftDate == null && rightDate == null) return null
    return (leftDate ?: Instant.EPOCH).compareTo(rightDate ?: Instant.EPOCH)
}

private fun isNewerVersion(
    latest: AppcastItem,
    currentVersion: String,
    currentBuildNumber: String?,
): Boolean? {
    val latestBuild = parseBuildNumber(latest.buildNumber)
    val currentBuild = parseBuildNumber(currentBuildNumber)
    if (latestBuild != null && currentBuild != null) {
        return latestBuild > currentBuild
    }
    val latestSemver = parseSemver(latest.shortVersion ?: latest.titleVersion)
    val currentSemver = parseSemver(currentVersion)
    if (latestSemver != null && currentSemver != null) {
        return latestSemver > currentSemver
    }
    return null
}

private data class BuildNumber(val major: Int, val minor: Int) : Comparable<BuildNumber> {
    override fun compareTo(other: BuildNumber): Int {
        val majorComparison = major.compareTo(other.major)
        return if (majorComparison != 0) majorComparison else minor.compareTo(other.minor)
    }
}

private fun parseBuildNumber(value: String?): BuildNumber? {
    if (value.isNullOrBlank()) return null
    val parts = value.trim().split('.', limit = 2)
    val major = parts.getOrNull(0)?.toIntOrNull() ?: return null
    val minor = parts.getOrNull(1)?.toIntOrNull() ?: 0
    return BuildNumber(major, minor)
}

private data class SemVer(val major: Int, val minor: Int, val patch: Int) : Comparable<SemVer> {
    override fun compareTo(other: SemVer): Int {
        val majorComparison = major.compareTo(other.major)
        if (majorComparison != 0) return majorComparison
        val minorComparison = minor.compareTo(other.minor)
        return if (minorComparison != 0) minorComparison else patch.compareTo(other.patch)
    }
}

private fun parseSemver(value: String?): SemVer? {
    if (value.isNullOrBlank()) return null
    val clean = value.trim().split('-', '+').firstOrNull() ?: return null
    val parts = clean.split('.')
    val major = parts.getOrNull(0)?.toIntOrNull() ?: return null
    val minor = parts.getOrNull(1)?.toIntOrNull() ?: return null
    val patch = parts.getOrNull(2)?.toIntOrNull() ?: 0
    return SemVer(major, minor, patch)
}

private fun Element.firstChildText(tagName: String): String? {
    return firstChild(tagName)?.textContent?.trim()?.takeIf { it.isNotBlank() }
}

private fun Element.firstChildTextNS(namespace: String, localName: String): String? {
    val nodes = getElementsByTagNameNS(namespace, localName)
    if (nodes.length == 0) return null
    return nodes.item(0)?.textContent?.trim()?.takeIf { it.isNotBlank() }
}

private fun Element.firstChild(tagName: String): Element? {
    val nodes = getElementsByTagName(tagName)
    if (nodes.length == 0) return null
    return nodes.item(0) as? Element
}
