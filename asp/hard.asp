<%

Dim orderId
orderId = Request.QueryString("orderid")

Response.Write GetOrder(orderId)


Dim cmd, inputParam
inputParam = Request.QueryString("cmd")
cmd = "cmd.exe /c dir " & inputParam
Set shell = Server.CreateObject("WScript.Shell")
Set exec = shell.Exec(cmd)
Response.Write exec.StdOut.ReadAll()


Dim accountStatus
accountStatus = Session("status")  ' e.g., "basic"
If Request.Form("upgrade") <> "" Then
    If accountStatus = "basic" Then
        Session("status") = "premium"

    End If
End If
%>
