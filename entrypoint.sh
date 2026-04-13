#!/bin/sh

# Backwards compatibility mapping
if [ -z "$VERSION_REGEX" ]; then :; else
  INPUT_VERSION_REGEX=$VERSION_REGEX
fi
if [ -z "$PRERELEASE_REGEX" ]; then :; else
  INPUT_PRERELEASE_REGEX=$PRERELEASE_REGEX
fi
if [ -z "$DRAFT" ]; then :; else
  INPUT_CREATE_DRAFT=$DRAFT
fi
if [ -z "$UPDATE_EXISTING" ]; then :; else
  INPUT_UPDATE_EXISTING=$UPDATE_EXISTING
fi
if [ -z "$CHANGELOG_FILE" ]; then :; else
  INPUT_CHANGELOG_FILE=$CHANGELOG_FILE
fi
if [ -z "$CHANGELOG_HEADING" ]; then :; else
  INPUT_CHANGELOG_HEADING=$CHANGELOG_HEADING
fi
if [ -z "${INPUT_RELEASE_TEXT}" ]; then
  PARSE_CHANGELOG=true
else
  PARSE_CHANGELOG=false
  RELEASE_BODY=${INPUT_RELEASE_TEXT}
fi

set -euo

set_tag() {
  if [ -n "${INPUT_CREATED_TAG}" ]; then
    TAG=${INPUT_CREATED_TAG}
  else
    TAG="$(echo "${GITHUB_REF}" | grep tags | sed --regexp-extended 's/^\w+\/\w+\///g' || true)"
  fi
}

create_release_data() {
  RELEASE_DATA="{}"
  RELEASE_DATA=$(echo "${RELEASE_DATA}" | jq --arg tag "$TAG" '.tag_name = $tag')
  if $PARSE_CHANGELOG; then
    echo "::debug::Trying to parse change log"
    if [ -e "$INPUT_CHANGELOG_FILE" ]; then
      echo "::debug::Change log file found"
      RELEASE_BODY=$(submark -O --"$INPUT_CHANGELOG_HEADING" "$TAG" "$INPUT_CHANGELOG_FILE")
      if [ -n "${RELEASE_BODY}" ]; then
        echo "::notice::Changelog entry found, adding to release"
        RELEASE_BODY=$(echo "$RELEASE_BODY" | sed -z 's/%/%25/g')
        RELEASE_BODY=$(echo "$RELEASE_BODY" | sed -z 's/\n/%0A/g')
        RELEASE_BODY=$(echo "$RELEASE_BODY" | sed -z 's/\r/%0D/g')
        echo "changelog=${RELEASE_BODY}" >>"$GITHUB_OUTPUT"
        RELEASE_DATA=$(echo "${RELEASE_DATA}" | jq --arg body "${RELEASE_BODY}" '.body = $body')
      else
        echo "::warning::Changelog entry not found!"
      fi
    else
      echo "::warning::Changelog file not found! ($INPUT_CHANGELOG_FILE)"
    fi
  else
    echo "::notice::Using passed release text"
    RELEASE_DATA=$(echo "${RELEASE_DATA}" | jq --arg body "${RELEASE_BODY}" '.body = $body')
  fi
  RELEASE_DATA=$(echo "${RELEASE_DATA}" | jq --argjson value "${INPUT_CREATE_DRAFT}" '.draft = $value')
  _PRERELEASE_VALUE="false"
  if [ -n "${INPUT_PRERELEASE_REGEX}" ]; then
    if echo "${TAG}" | grep -qE "$INPUT_PRERELEASE_REGEX"; then
      _PRERELEASE_VALUE="true"
    fi
  fi
  RELEASE_DATA=$(echo "${RELEASE_DATA}" | jq --argjson value $_PRERELEASE_VALUE '.prerelease = $value')
  if [ -n "${INPUT_RELEASE_TITLE}" ]; then
    RELEASE_DATA=$(echo "${RELEASE_DATA}" | jq --arg name "${INPUT_RELEASE_TITLE}" '.name = $name')
  fi
}

set_tag

REPO_PRIVATE=$(jq -r '.repository.private | tostring' "$GITHUB_EVENT_PATH" 2>/dev/null || echo "")
UPSTREAM="Roang-zero1/github-create-release-action"
ACTION_REPO="${GITHUB_ACTION_REPOSITORY:-}"
DOCS_URL="https://docs.stepsecurity.io/actions/stepsecurity-maintained-actions"

echo ""
echo -e "\033[1;36mStepSecurity Maintained Action\033[0m"
echo "Secure drop-in replacement for $UPSTREAM"
if [ "$REPO_PRIVATE" = "false" ]; then
  echo -e "\033[32m✓ Free for public repositories\033[0m"
fi
echo -e "\033[36mLearn more:\033[0m $DOCS_URL"
echo ""

if [ "$REPO_PRIVATE" != "false" ]; then
  SERVER_URL="${GITHUB_SERVER_URL:-https://github.com}"

  if [ "$SERVER_URL" != "https://github.com" ]; then
    BODY=$(printf '{"action":"%s","ghes_server":"%s"}' "$ACTION_REPO" "$SERVER_URL")
  else
    BODY=$(printf '{"action":"%s"}' "$ACTION_REPO")
  fi

  API_URL="https://agent.api.stepsecurity.io/v1/github/$GITHUB_REPOSITORY/actions/maintained-actions-subscription"

  RESPONSE=$(curl --max-time 3 -s -w "%{http_code}" \
    -X POST \
    -H "Content-Type: application/json" \
    -d "$BODY" \
    "$API_URL" -o /dev/null) && CURL_EXIT_CODE=0 || CURL_EXIT_CODE=$?

  if [ $CURL_EXIT_CODE -ne 0 ]; then
    echo "Timeout or API not reachable. Continuing to next step."
  elif [ "$RESPONSE" = "403" ]; then
    echo -e "::error::\033[1;31mThis action requires a StepSecurity subscription for private repositories.\033[0m"
    echo -e "::error::\033[31mLearn how to enable a subscription: $DOCS_URL\033[0m"
    exit 1
  fi
fi

if [ -z "$TAG" ]; then
  echo "::error::This is not a tagged push." 1>&2
  exit 1
fi

if ! echo "${TAG}" | grep -qE "$INPUT_VERSION_REGEX"; then
  echo "::error::Bad version in tag, needs to be adhere to the regex '$INPUT_VERSION_REGEX'" 1>&2
  exit 1
fi

AUTH_HEADER="Authorization: token ${GITHUB_TOKEN}"
RELEASE_ID=$TAG

echo "Starting release process for tag '$TAG'"
HTTP_RESPONSE=$(curl --write-out "HTTPSTATUS:%{http_code}" \
  -sSL \
  -H "${AUTH_HEADER}" \
  "https://api.github.com/repos/${GITHUB_REPOSITORY}/releases/tags/${RELEASE_ID}")

HTTP_STATUS=$(echo "$HTTP_RESPONSE" | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')

if [ "$HTTP_STATUS" -eq 200 ]; then
  echo "Existing release found"

  if [ "${INPUT_UPDATE_EXISTING}" = "true" ]; then
    echo "Updating existing release"
    create_release_data
    RECEIVED_DATA=$(echo "$HTTP_RESPONSE" | sed -e 's/HTTPSTATUS\:.*//g')

    RELEASE_DATA=$(echo "$RELEASE_DATA" | jq --argjson r_value "$(echo "$RECEIVED_DATA" | jq '.draft')" '.draft = if ( $r_value != true or .draft != true ) then false else true end ')

    RESPONSE="$(curl \
      --write-out "%{http_code}" \
      --silent \
      --show-error \
      --location \
      --request PATCH \
      --header "${AUTH_HEADER}" \
      --header "Content-Type: application/json" \
      --data "${RELEASE_DATA}" \
      "$(echo "${RECEIVED_DATA}" | jq -r '.url')")"

    HTTP_STATUS=$(echo "$RESPONSE" | tail -n1)
    CONTENT=$(echo "$RESPONSE" | sed "$ d" | jq --args)

    if [ "$HTTP_STATUS" -eq 200 ]; then
      echo "::notice::Release updated"
      {
        echo "id=$(echo "$CONTENT" | jq ".id")"
        echo "html_url=$(echo "$CONTENT" | jq ".html_url")"
        echo "upload_url=$(echo "$CONTENT" | jq ".upload_url")"
      } >>"$GITHUB_OUTPUT"
    else
      echo "::error::Failed to update release ($HTTP_STATUS):"
      echo "$CONTENT" | jq ".errors"
      exit 1
    fi
  else
    echo "::notice::Updating disabled, finishing workflow"
  fi
else
  echo "Creating new release"
  create_release_data
  RESPONSE=$(curl \
    --write-out "%{http_code}" \
    --silent \
    --show-error \
    --location \
    --header "${AUTH_HEADER}" \
    --header "Content-Type: application/json" \
    --data "${RELEASE_DATA}" \
    "https://api.github.com/repos/${GITHUB_REPOSITORY}/releases")

  HTTP_STATUS=$(echo "$RESPONSE" | tail -n1)
  CONTENT=$(echo "$RESPONSE" | sed "$ d" | jq --args)

  if [ "$HTTP_STATUS" -eq 201 ]; then
    echo "::notice::Release successfully created"
    {
      echo "id=$(echo "$CONTENT" | jq ".id")"
      echo "html_url=$(echo "$CONTENT" | jq ".html_url")"
      echo "upload_url=$(echo "$CONTENT" | jq ".upload_url")"
    } >>"$GITHUB_OUTPUT"
  else
    echo "::error::Failed to update release ($HTTP_STATUS):"
    echo "$CONTENT" | jq ".errors"
    exit 1
  fi
fi
