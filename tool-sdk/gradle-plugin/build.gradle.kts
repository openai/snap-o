import com.vanniktech.maven.publish.GradlePlugin
import com.vanniktech.maven.publish.JavadocJar
import com.vanniktech.maven.publish.SourcesJar
import java.util.Properties

plugins {
    `kotlin-dsl`
    id("com.vanniktech.maven.publish") version "0.36.0"
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
        register("snapoTool") {
            id = "com.openai.snapo.tool"
            implementationClass = "com.openai.snapo.gradle.ToolPackagingPlugin"
            displayName = "Snap-O tool"
            description = project.description
        }
    }
}

allprojects {
    group = rootProject.group
    version = rootProject.version
    description = if (path == ":") rootProject.description else "Configures Node.js downloads for Snap-O tools."
    pluginManager.withPlugin("java-gradle-plugin") {
        apply(plugin = "com.vanniktech.maven.publish")
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
    }
}
