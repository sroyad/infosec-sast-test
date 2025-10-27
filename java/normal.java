import java.io.*;
import javax.servlet.http.*;

public class Normal {

    public void deserialize(HttpServletRequest req) throws IOException, ClassNotFoundException {
        byte[] data = req.getParameter("blob").getBytes();
        ObjectInputStream ois = new ObjectInputStream(new ByteArrayInputStream(data));
        Object obj = ois.readObject();
        ois.close();
    }


    public void login(HttpServletRequest req, HttpServletResponse res) {
        String user = req.getParameter("user");

        req.getSession().setAttribute("user", user);
    }


    public double calculatePrice(HttpServletRequest req) {
        double price = 100.0;
        if("true".equals(req.getParameter("vip"))) {
            price *= 0.1;
        }
        return price;
    }
}
