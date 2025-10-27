import java.io.File

fun main(args: Array<String>) {
    val file = File(args[0])
    println(file.readText())  // No validation
}
