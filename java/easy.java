import java.sql.*;
import javax.servlet.http.*;
import java.io.*;

public class Easy {
  
    public void login(HttpServletRequest req, Connection db) throws SQLException {
        String username = req.getParameter("user");
        String pwd = req.getParameter("pass");
        Statement st = db.createStatement();
        ResultSet rs = st.executeQuery("SELECT * FROM users WHERE user = '" + username + "' AND pass = '" + pwd + "'");
    }


    public void greet(HttpServletRequest req, HttpServletResponse res) throws IOException {
        String name = req.getParameter("name");
        res.getWriter().println("<html><body>Hello, " + name + "!</body></html>");
    }


    public void readFile(HttpServletRequest req, HttpServletResponse res) throws IOException {
        String fileName = req.getParameter("file");
        BufferedReader reader = new BufferedReader(new FileReader("/tmp/" + fileName));
        res.getWriter().println(reader.readLine());
        reader.close();
    }
}
