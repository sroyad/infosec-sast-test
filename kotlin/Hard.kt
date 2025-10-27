import java.io.File
import java.nio.file.Files

fun main(args: Array<String>) {
    val tmp = Files.createTempFile("tmp", ".txt")
    File(tmp.toUri()).writeText("some text")
    println(File(tmp.toUri()).readText())
}
