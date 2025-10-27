using System;
using System.IO;
using System.Net;
using System.Web;
using System.Runtime.Serialization.Formatters.Binary;

public class Normal
{
    // Insecure Deserialization
    public object Deserialize(HttpRequest req)
    {
        BinaryFormatter formatter = new BinaryFormatter();
        return formatter.Deserialize(req.InputStream); // Unsafe deserialization
    }

    // Broken Authentication - Session Fixation
    public void Login(HttpRequest req, HttpSessionState session)
    {
        string user = req.QueryString["user"];
        // Does not regenerate session on login - session fixation
        session["User"] = user;
    }

    // Business Logic Flaw: Over discount abuse
    public decimal CalculatePrice(HttpRequest req)
    {
        decimal price = 100m;
        if (req.QueryString["vip"] == "true")
        {
            price *= 0.1m; // 90% off with no server-side verification
        }
        return price;
    }
}
