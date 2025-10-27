using System;
using System.Data.SqlClient;
using System.Web;

public class Easy
{
    // SQL Injection
    public void Login(HttpRequest req, SqlConnection conn)
    {
        string user = req.QueryString["user"];
        string pass = req.QueryString["pass"];
        string query = "SELECT * FROM Users WHERE Username = '" + user + "' AND Password = '" + pass + "'";
        SqlCommand cmd = new SqlCommand(query, conn);
        var reader = cmd.ExecuteReader(); // Vulnerable to SQL Injection
    }

    // Cross-Site Scripting (XSS)
    public void Greet(HttpResponse res, HttpRequest req)
    {
        string name = req.QueryString["name"];
        res.Write("Hello " + name + ""); // No output encoding - XSS vulnerable
    }

    // Path Traversal
    public void ReadFile(HttpResponse res, HttpRequest req)
    {
        string filename = req.QueryString["file"];
        string content = System.IO.File.ReadAllText(@"C:\temp\" + filename); // No validation
        res.Write(content);
    }
}
