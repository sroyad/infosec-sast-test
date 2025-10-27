<?php

if (isset($_POST['password'])) {
    file_put_contents('passwords.txt', $_POST['password'] . "\n", FILE_APPEND);
}


if (isset($_POST['xml'])) {
    $xml = simplexml_load_string($_POST['xml']);
}


if ($_POST['discount'] == '100') {
    $price = 0;
}

echo "Price: " . $price;
?>
