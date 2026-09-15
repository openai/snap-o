import com.github.gradle.node.npm.task.NpmTask
import com.vanniktech.maven.publish.GradlePlugin
import com.vanniktech.maven.publish.JavadocJar
import com.vanniktech.maven.publish.SourcesJar
import java.util.Properties
import groovy.json.JsonOutput
import groovy.json.JsonSlurper

plugins {
    `kotlin-dsl`
    id("com.github.node-gradle.node") version "7.1.0"
    id("com.vanniktech.maven.publish") version "0.36.0"
}

node {
    version.set("22.23.2")
    download.set(true)
    nodeProjectDir.set(file("../host"))
    npmInstallCommand.set("ci")
}

val hostDist = layout.buildDirectory.dir("host-sdk/dist")
val buildHostSdk = tasks.register<NpmTask>("buildHostSdk") {
    dependsOn("npmInstall")
    npmCommand.set(listOf("run", "build", "--", "--outDir", hostDist.get().asFile.absolutePath))
    inputs.files(fileTree("../host/src") { exclude("**/*.test.ts") }, file("../host/tsconfig.json"),
        file("../host/tsconfig.build.json"), file("../host/package.json"), file("../host/package-lock.json"))
    outputs.dir(hostDist)
    doFirst { hostDist.get().asFile.deleteRecursively() }
}

val hostMetadata = file("../host/package.json")
val hostPackage = layout.buildDirectory.file("host-sdk/package.json")
val writeHostPackage = tasks.register("writeHostPackage") {
    inputs.file(hostMetadata)
    outputs.file(hostPackage)
    doLast {
        val metadata = JsonSlurper().parse(hostMetadata) as Map<*, *>
        require((metadata["dependencies"] as Map<*, *>).isEmpty()) { "The host SDK must have no runtime dependencies" }
        // Gradle supplies the SDK version. npm only needs its local module entry point.
        val runtime = metadata.filterKeys { it in setOf("name", "private", "type", "exports", "types", "license") }
        hostPackage.get().asFile.apply {
            parentFile.mkdirs()
            writeText(JsonOutput.prettyPrint(JsonOutput.toJson(runtime)) + "\n")
        }
    }
}

val bundleHostSdk = tasks.register<Zip>("bundleHostSdk") {
    archiveFileName.set("host-sdk.zip")
    destinationDirectory.set(layout.buildDirectory.dir("host-sdk-bundle"))
    isPreserveFileTimestamps = false
    isReproducibleFileOrder = true
    from(writeHostPackage)
    from("../host") { include("README.md", "LICENSE") }
    into("dist") { from(buildHostSdk) }
}

tasks.processResources {
    from(bundleHostSdk) { into("host-sdk") }
}

val androidProperties = Properties().apply { file("../../gradle.properties").inputStream().use(::load) }
group = androidProperties.getProperty("GROUP") ?: error("Missing GROUP")
version = file("../../VERSION").readLines()
    .first { it.substringBefore('=').trim() == "VERSION" }.substringAfter('=').trim()
description = "Packages app-bundled Snap-O tool frontends and discovery metadata."

repositories {
    google()
    mavenCentral()
    gradlePluginPortal()
}

dependencies {
    compileOnly("com.android.tools.build:gradle-api:9.0.0")
    implementation("com.github.node-gradle:gradle-node-plugin:7.1.0")
    implementation("org.apache.commons:commons-compress:1.28.0")
    testImplementation("junit:junit:4.13.2")
}

gradlePlugin {
    plugins {
        register("snapoToolPackager") {
            id = "com.openai.snapo.tool-packager"
            implementationClass = "com.openai.snapo.gradle.ToolPackagerPlugin"
            displayName = "Snap-O Tool Packager"
            description = project.description
        }
    }
}

extensions.configure<com.vanniktech.maven.publish.MavenPublishBaseExtension> {
    configure(GradlePlugin(JavadocJar.Empty(), SourcesJar.Sources()))
    coordinates(group.toString(), project.name, version.toString())
    publishToMavenCentral(automaticRelease = false)
    signAllPublications()
    pom {
        name.set(project.name)
        description.set(project.description)
        url.set("https://github.com/openai/snap-o")
        inceptionYear.set("2025")
        licenses {
            license {
                name.set("The Apache License, Version 2.0")
                url.set("https://www.apache.org/licenses/LICENSE-2.0.txt")
                distribution.set("repo")
            }
        }
        developers {
            developer {
                id.set("openai")
                name.set("OpenAI")
                url.set("https://openai.com")
            }
        }
        scm {
            url.set("https://github.com/openai/snap-o")
            connection.set("scm:git:https://github.com/openai/snap-o.git")
            developerConnection.set("scm:git:ssh://git@github.com/openai/snap-o.git")
        }
    }
}

extensions.configure<org.gradle.api.publish.PublishingExtension> {
    repositories {
        maven {
            name = "Authoring"
            url = uri(providers.gradleProperty("snapo.authoringRepository")
                .getOrElse(layout.buildDirectory.dir("authoring-repository").get().asFile.absolutePath))
            require(url.scheme == "file") { "Authoring publications require a local directory" }
        }
    }
}

// Local consumer tests use unsigned artifacts; Central publications still require signing.
tasks.withType<Sign>().configureEach {
    onlyIf { !providers.gradleProperty("snapo.localAuthoring").map(String::toBoolean).getOrElse(false) }
}

tasks.register("assembleMavenCentralPublication") {
    group = "publishing"
    description = "Assembles the plugin implementation and marker without uploading them."
    dependsOn("jar", "sourcesJar", "emptyJavadocJar")
    dependsOn(tasks.withType<GenerateMavenPom>(), tasks.withType<GenerateModuleMetadata>())
}
