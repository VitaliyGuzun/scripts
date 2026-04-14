###############
## Client tests
###############
switch-dev() { serverName="${1:-released}"; cd e2e-tests/client && yarn spectator switch -n dev-custom -s "$serverName" && cd ../../; }
switch-local() { serverName="${1:-released}"; cd e2e-tests/client && yarn spectator switch -n local-custom -s "$serverName" && cd ../../; }
switch-env() { envNumber="${1:-12}";  client="${2:-local}"; cd e2e-tests/client && yarn spectator switch -n autotests-"${envNumber}" -c "$client" && cd ../..; }
switch-which() { cat e2e-tests/client/spectator/.local_spectator; }
vtest-docker() { allureId="${1}"; repeat="${2:-0}"; cd e2e-tests/client && yarn spectator test --docker --allure-id "${allureId}" -f "${repeat}" && cd ../..; }
vtest() { allureId="${1}"; repeat="${2:-0}"; cd e2e-tests/client && yarn spectator test --allure-id "${allureId}" -f "${repeat}" && cd ../..; }

###############
## Client
###############
vstart() { npx nx reset && nvm use && yarn start }
