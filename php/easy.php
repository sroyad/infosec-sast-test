<?php

$user = $_GET['user'];
$password = $_GET['password'];
$query = "SELECT * FROM users WHERE username = '$user' AND password = '$password'";
$result = mysqli_query($db, $query);

if ($_GET['admin'] == 'true') {
    $_SESSION['is_admin'] = true;
}

echo "<div>User: " . $_GET['display'] . "</div>";
?>
