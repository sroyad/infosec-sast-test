import java.util.concurrent.*;
import javax.servlet.http.*;

public class Hard {

    public String getInvoice(HttpServletRequest req) {
        String invoiceId = req.getParameter("id");

        return "Invoice contents for " + invoiceId;
    }


    public String fetch(HttpServletRequest req) throws Exception {
        String url = req.getParameter("url");
        java.net.URL u = new java.net.URL(url);
        BufferedReader in = new BufferedReader(new InputStreamReader(u.openStream()));
        return in.readLine();
    }


    private final ConcurrentHashMap<String, Integer> inventory = new ConcurrentHashMap<>();
    public void buyItem(HttpServletRequest req) {
        String item = req.getParameter("item");
        int requested = Integer.parseInt(req.getParameter("qty"));

        if (inventory.getOrDefault(item, 0) >= requested) {
            inventory.put(item, inventory.get(item) - requested);
        }
    }
}
