using System;
using System.Net;
using System.Web;
using System.Collections.Concurrent;
using System.Threading;

public class Hard
{
    // Insecure Direct Object Reference (IDOR)
    public string GetInvoice(HttpRequest req)
    {
        string invoiceId = req.QueryString["id"];
        // No check if user is authorized to access invoiceId
        return $"Invoice details for {invoiceId}";
    }

    // SSRF vulnerability
    public string FetchUrl(HttpRequest req)
    {
        string url = req.QueryString["url"];
        using (WebClient client = new WebClient())
        {
            return client.DownloadString(url); // No validation on URL
        }
    }

    // Race condition in order processing
    private static ConcurrentDictionary<string, int> inventory = new ConcurrentDictionary<string, int>()
    {
        ["item1"] = 10
    };

    public void BuyItem(HttpRequest req)
    {
        string item = req.QueryString["item"];
        int qty = int.Parse(req.QueryString["qty"]);

        if (inventory.ContainsKey(item) && inventory[item] >= qty)
        {
            // Not atomic update, race condition possible
            inventory[item] -= qty;
        }
    }
}
