###############
## Client tests
###############

# Examples:
# switch-local released (default)
# switch-local lastmaster
# switch-local your-custom-server-name from https://devconsole.develop.testmiro.com/

switch-local() {
  local serverName="${1:-released}"
  cd e2e-tests/client && yarn spectator switch -n local-custom -s "$serverName"
  cd ../../
}

# Examples:
# switch-env autotests-12 local (default)
# switch-env staging-eu02 your-custom-client-version from CI/CD (1.94983.0 for example)

switch-env() {
  local envName="${1:-autotests-12}"
  local client="${2:-local}"
  cd e2e-tests/client && yarn spectator switch -n "${envName}" -c "$client"
  cd ../..
}

# Just print your current spectator settings
switch-which() {
  cat e2e-tests/client/spectator/.local_spectator
}

# Tests with docker - this checks screenshots too
vtest-docker() {
  local allureId="${1}"
  local repeat="${2:-0}"
  cd e2e-tests/client && yarn spectator test --docker --allure-id "${allureId}" -f "${repeat}"
  cd ../..
}

# Tests without docker - this does not check screenshots
vtest() {
  local allureId="${1}"
  local repeat="${2:-0}"
  cd e2e-tests/client && yarn spectator test --allure-id "${allureId}" -f "${repeat}"
  cd ../..
}

###############
## Client
###############

vstart() {
  npx nx reset && nvm use && yarn start
}
