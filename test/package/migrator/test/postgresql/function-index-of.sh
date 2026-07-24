# shellcheck disable=SC2034
AS_LIBRARY= 
# shellcheck disable=SC1090
. "$(which migrator)"

array='item1 
item2
item3
item4
item5
item6
item7'

log notice "test case: ${WHITE}index of"
if ! answer=$(index_of "$array" 'item4'); then
  log error "test failed: ${WHITE}error during index_of call"
  exit 1
fi

is_number "$answer" >/dev/null || { log error "test failed: ${WHITE}answer not a number"; exit 1; }

if [ "$answer" -ne 4 ]; then
  log error "test failed: ${WHITE}wrong answer"
  exit 1
fi

log notice "test case: ${WHITE}unguarded assignment under errexit"
answer=$(index_of "$array" 'item4')

if [ "$answer" -ne 4 ]; then
  log error "test failed: ${WHITE}wrong answer from unguarded assignment"
  exit 1
fi

log notice "test case: ${WHITE}error: item not found"
if answer=$(index_of "$array" 'item10'); then
  log error "test failed: ${WHITE} must return an error"
  exit 1
fi

log notice "test case: ${WHITE}one element"
array='20251104192425-add-info-to-profile' 
item='20251104192425-add-info-to-profile' 

if ! answer=$(index_of "$array" "$item"); then
  log error "test failed: ${WHITE}error during index_of call"
  exit 1
fi

if [ "$answer" -ne 1 ]; then
  log error "test failed: ${WHITE}wrong answer"
  exit 1
fi

log notice "test passed"
