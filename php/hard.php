<?php

if ($_GET['user_id']) {
    $userId = $_GET['user_id'];
    $order = getOrderDetails($userId); 
    echo json_encode($order);
}


if (isset($_POST['cookie'])) {
    $obj = unserialize($_POST['cookie']);
}


if (isset($_POST['upgrade'])) {

    if ($account->status == 'basic') {
        $account->status = 'premium';
        saveAccount($account);
    }
}
?>
