// Minimal cacheable build. JavaCompile is cacheable, so `clean build` twice with
// the local cache disabled is a clean remote-cache experiment.
plugins { `java-library` }

java { toolchain { languageVersion = JavaLanguageVersion.of(21) } }

// One extra cacheable task with a deliberately identifiable output, so the
// --info log names something other than compileJava.
val stamp by tasks.registering {
    val out = layout.buildDirectory.file("stamp.txt")
    inputs.property("content", "gbc-probe")
    outputs.file(out).withPropertyName("stamp")
    outputs.cacheIf { true }
    doLast { out.get().asFile.writeText("gbc-probe\n") }
}
tasks.named("build") { dependsOn(stamp) }
