#!/bin/bash
# Race condition
TEMP=$(mktemp)
echo "data" > $TEMP
cat $TEMP
rm $TEMP
