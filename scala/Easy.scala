object Easy {
  def main(args: Array[String]): Unit = {
    import sys.process._
    val cmd = scala.io.StdIn.readLine()
    cmd.!  // Dangerous execution
  }
}
