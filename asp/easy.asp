<%

Dim user, pass, sql, rs
user = Request.QueryString("user")
pass = Request.QueryString("pass")
sql = "SELECT * FROM users WHERE username = '" & user & "' AND password = '" & pass & "'"
Set rs = conn.Execute(sql)  


Dim display
display = Request.QueryString("display")
Response.Write "<div>User: " & display & "</div>"  


Dim fso, file
Set fso = Server.CreateObject("Scripting.FileSystemObject")
Set file = fso.OpenTextFile(Server.MapPath("config.txt"), 1)
Response.Write file.ReadAll()  
file.Close
Set file = Nothing
Set fso = Nothing
%>
