#!/bin/bash

# These should definitely trigger ShellCheck warnings/errors

# Unquoted variable expansion (should trigger SC2086)
echo $USER

# Use of cat where better tools exist (should trigger SC2002)  
cat /etc/passwd | grep root

# Dangerous rm command (should trigger warnings)
rm -rf $HOME/tmp

# Using [ instead of [[ (should trigger SC2009)
if [ $USER = "root" ]; then
    echo "Admin user"
fi

# Command substitution with backticks (should trigger SC2006)  
result=`ls -la`

# Double-quoted array expansion (should trigger SC2145)
array=("one" "two" "three")
echo "$array[*]"

# Potential word splitting (should trigger SC2086)
file="my file.txt"
touch $file

# Use of deprecated egrep (should trigger SC2196)
echo "test" | egrep "t.*t"

# Dangerous eval usage
user_cmd="ls -la"
eval $user_cmd
