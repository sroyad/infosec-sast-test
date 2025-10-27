<%

Dim xml, xmlDoc
xml = Request.Form("xml")
Set xmlDoc = Server.CreateObject("Microsoft.XMLDOM")
xmlDoc.async = False
xmlDoc.loadXML(xml)   


If Request.QueryString("user") <> "" Then
    Session("user") = Request.QueryString("user")  
End If


Dim discount, price
discount = Request.Form("discount")
price = 100
If discount = "100" Then
    price = 0  
End If
Response.Write "Price: " & price
%>
