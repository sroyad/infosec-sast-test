import java.io._
object Hard {
  def main(args: Array[String]): Unit = {
    val file = new File(args(0))
    if (file.exists()) {
      val fis = new FileInputStream(file)
      val buffer = new Array[Byte](fis.available())
      fis.read(buffer)
      println(new String(buffer))
    }
  }
}
