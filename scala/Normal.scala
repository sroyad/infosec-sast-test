object Normal {
  def main(args: Array[String]): Unit = {
    val file = scala.io.Source.fromFile(args(0))
    println(file.mkString)
    file.close()
  }
}
