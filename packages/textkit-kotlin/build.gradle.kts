import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    kotlin("jvm") version "2.0.21"
    kotlin("plugin.serialization") version "2.0.21"
    `java-library`
    `maven-publish`
}

group = "com.jointextkit"
version = "0.1.0"

repositories {
    mavenCentral()
}

dependencies {
    // The only runtime dependency (besides the Kotlin stdlib). No reflection:
    // the (de)serializers are generated at compile time. See README "Why
    // kotlinx.serialization".
    api("org.jetbrains.kotlinx:kotlinx-serialization-json:1.7.3")

    testImplementation(platform("org.junit:junit-bom:5.11.3"))
    testImplementation("org.junit.jupiter:junit-jupiter")
    testRuntimeOnly("org.junit.platform:junit-platform-launcher")
}

java {
    // Compiled by any JDK 11+; runs on Java 11 and later.
    sourceCompatibility = JavaVersion.VERSION_11
    targetCompatibility = JavaVersion.VERSION_11
    withSourcesJar()
    withJavadocJar()
}

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_11)
        // Link against the Java 11 API so nothing newer slips in.
        freeCompilerArgs.addAll("-Xjdk-release=11", "-Xjvm-default=all")
    }
}

tasks.withType<JavaCompile>().configureEach {
    options.release.set(11)
}

tasks.test {
    useJUnitPlatform()
    testLogging {
        events("failed")
        exceptionFormat = org.gradle.api.tasks.testing.logging.TestExceptionFormat.FULL
    }
}

tasks.jar {
    manifest {
        attributes(
            "Implementation-Title" to "textkit",
            "Implementation-Version" to project.version,
            "Automatic-Module-Name" to "com.jointextkit",
        )
    }
}

publishing {
    publications {
        create<MavenPublication>("maven") {
            artifactId = "textkit"
            from(components["java"])
            pom {
                name.set("TextKit")
                description.set("Official Kotlin and Java client for TextKit (jointextkit.com): SMS, phone verification, and phone numbers.")
                url.set("https://jointextkit.com")
                licenses {
                    license {
                        name.set("MIT")
                        url.set("https://opensource.org/licenses/MIT")
                    }
                }
                organization {
                    name.set("Truelabel Inc")
                }
            }
        }
    }
}
