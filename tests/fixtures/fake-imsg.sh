#!/usr/bin/env bash
set -Eeuo pipefail

readonly fixture_prefix="${TMPDIR%/}/fake-imsg"
readonly log_file="${fixture_prefix}.log"
{
  printf 'imsg'
  printf ' %q' "$@"
  printf '\n'
} >> "$log_file"

if [[ "${1:-}" == "--version" && "$#" -eq 1 ]]; then
  dependency_version='0.13.4'
  if [[ -f "${fixture_prefix}.version" ]]; then
    IFS= read -r dependency_version < "${fixture_prefix}.version"
  fi
  printf '%s\n' "$dependency_version"
  exit 0
fi

command_name="${1:-}"
[[ -n "$command_name" ]] || exit 64
shift

malformed_kind=''
if [[ -f "${fixture_prefix}.malformed" ]]; then
  IFS= read -r malformed_kind < "${fixture_prefix}.malformed"
fi

has_argument() {
  local expected="$1" argument
  shift
  for argument in "$@"; do
    [[ "$argument" == "$expected" ]] && return 0
  done
  return 1
}

option_value() {
  local expected="$1" previous='' argument
  shift
  for argument in "$@"; do
    if [[ "$previous" == "$expected" ]]; then
      printf '%s\n' "$argument"
      return 0
    fi
    previous="$argument"
  done
  return 1
}

has_argument --json "$@" || {
  printf 'fake imsg requires --json\n'
  exit 64
}
database_path="$(option_value --db "$@" || true)"
[[ -n "$database_path" ]] || {
  printf 'fake imsg requires the fixed --db path\n'
  exit 64
}
if [[ -f "${fixture_prefix}.expected-db" ]]; then
  IFS= read -r expected_database_path < "${fixture_prefix}.expected-db"
  [[ "$database_path" == "$expected_database_path" ]] || {
    printf 'fake imsg received an unexpected database path\n'
    exit 64
  }
fi

case "$command_name" in
  chats)
    if [[ "$malformed_kind" == chat ]]; then
      printf '%s\n' \
        '{"id":42,"name":"Test Chat","display_name":42,"identifier":"iMessage;-;+15551234567","service":"iMessage","is_group":false,"participants":["+15551234567"]}'
      exit 0
    fi
    printf '%s\n' \
      '{"id":42,"name":"Test Chat","identifier":"iMessage;-;+15551234567","service":"iMessage","last_message_at":"2026-08-09T12:00:00.000Z","guid":"iMessage;-;+15551234567","display_name":"Private display","contact_name":"Private contact","is_group":false,"participants":["+15551234567"],"account_id":"private-account-id","account_login":"private@example.test","last_addressed_handle":"private@example.test","unread_count":1}'
    ;;
  group)
    chat_id="$(option_value --chat-id "$@" || true)"
    [[ "$chat_id" == 42 ]] || {
      printf 'Chat not found: %s\n' "$chat_id"
      exit 1
    }
    if [[ -f "${fixture_prefix}.shared-send-deadline" ]]; then
      sleep 1.25
    fi
    printf '%s\n' \
      '{"id":42,"identifier":"iMessage;-;+15551234567","guid":"iMessage;-;+15551234567","name":"Test Chat","service":"iMessage","is_group":false,"participants":["+15551234567"],"account_id":"private-account-id","account_login":"private@example.test","last_addressed_handle":"private@example.test"}'
    ;;
  chat-background)
    [[ "${1:-}" == status ]] || exit 64
    chat_id="$(option_value --chat-id "$@" || true)"
    [[ "$chat_id" == 42 ]] || {
      printf 'chat not found\n'
      exit 1
    }
    if [[ "$malformed_kind" == background ]]; then
      printf '%s\n' \
        '{"ok":true,"chat_id":42,"chat_guid":"iMessage;-;+15551234567","background_set":"yes"}'
      exit 0
    fi
    printf '%s\n' \
      '{"ok":true,"chat_id":42,"chat_guid":"iMessage;-;+15551234567","background_set":true,"background_channel_guid":"private-background-channel","asset_url":"https://private.example.test/background?token=secret","asset_id":"private-asset-id","object_id":"private-object-id","file_size":2048,"poster_version":-3,"communication_safety_state":-1,"version":-2,"cache_path":"/Users/kleo/Library/Messages/TranscriptBackgroundCache/private","cache_exists":true,"watch_background_path":"/Users/kleo/Library/Messages/TranscriptBackgroundCache/private-watchBackground","watch_background_exists":false,"latest_event":{"row_id":-400,"guid":"private-background-event-guid","action":"set","date":"2026-08-09T12:03:00.000Z"}}'
    ;;
  history)
    chat_id="$(option_value --chat-id "$@" || true)"
    [[ "$chat_id" == 42 ]] || {
      printf 'chat not found\n'
      exit 1
    }
    if has_argument --participants "$@"; then
      [[ "$(option_value --participants "$@")" == '+15551234567,me@example.test' ]] || {
        printf 'unexpected participant filter\n'
        exit 64
      }
    fi
    if [[ "$malformed_kind" == attachment ]]; then
      printf '%s\n' \
        '{"id":100,"chat_id":42,"guid":"message-guid-100","sender":"+15551234567","is_from_me":false,"text":"hello","created_at":"2026-08-09T12:00:00.000Z","attachments":[{"filename":42}],"reactions":[]}'
      exit 0
    fi
    if [[ "$malformed_kind" == message ]]; then
      printf '%s\n' \
        '{"id":100,"chat_id":42,"guid":"message-guid-100","reply_to_guid":42,"sender":"+15551234567","is_from_me":false,"text":"hello","created_at":"2026-08-09T12:00:00.000Z","attachments":[],"reactions":[]}'
      exit 0
    fi
    if [[ "$malformed_kind" == reaction ]]; then
      printf '%s\n' \
        '{"id":100,"chat_id":42,"guid":"message-guid-100","sender":"+15551234567","is_from_me":false,"text":"hello","created_at":"2026-08-09T12:00:00.000Z","attachments":[],"reactions":[{"id":1,"type":"love","emoji":"heart","sender":"+15551234567","sender_name":42,"is_from_me":false,"created_at":"2026-08-09T12:00:01.000Z"}]}'
      exit 0
    fi
    printf '%s\n' \
      '{"id":101,"chat_id":42,"guid":"message-guid-101","sender":"me@example.test","sender_name":null,"is_from_me":true,"text":"reply","created_at":"2026-08-09T12:01:00.000Z","attachments":[],"reactions":[],"destination_caller_id":"private-line"}' \
      '{"id":100,"chat_id":42,"guid":"message-guid-100","sender":"+15551234567","sender_name":"Private contact","is_from_me":false,"text":"hello","created_at":"2026-08-09T12:00:00.000Z","attachments":[{"filename":"/Users/kleo/Library/Messages/Attachments/secret.jpg","uti":"public.jpeg","mime_type":"image/jpeg","total_bytes":123,"is_sticker":false,"original_path":"/Users/kleo/Library/Messages/Attachments/secret.jpg","converted_path":"/private/tmp/secret.jpg","converted_mime_type":"image/jpeg","missing":false},{"filename":"","mime_type":null,"uti":null,"total_bytes":0,"is_sticker":null}],"reactions":[],"destination_caller_id":"private-line","balloon_bundle_id":null,"url_preview":null,"poll":null,"is_read":false,"date_read":null}'
    ;;
  scheduled)
    [[ "${1:-}" == list ]] || exit 64
    if [[ "$malformed_kind" == scheduled ]]; then
      printf '%s\n' \
        '{"id":200,"guid":"scheduled-guid-200","chat_id":42,"chat_name":"Test Chat","text":"later","service":"iMessage","scheduled_at":"2026-08-10T12:00:00.000Z","schedule_state":"invalid"}'
      exit 0
    fi
    printf '%s\n' \
      '{"id":200,"guid":"scheduled-guid-200","chat_id":42,"chat_identifier":"iMessage;-;+15551234567","chat_guid":"iMessage;-;+15551234567","chat_name":"Test Chat","text":"later","service":"iMessage","scheduled_at":"2026-08-10T12:00:00.000Z","schedule_type":1,"schedule_state":0}'
    ;;
  stats)
    chat_id="$(option_value --chat-id "$@" || true)"
    if [[ "$chat_id" == 999 ]]; then
      printf 'chat_id 999 does not exist\n'
      exit 1
    fi
    if [[ "$malformed_kind" == statistics-date ]]; then
      printf '%s\n' \
        '{"total_messages":1,"sent_messages":1,"received_messages":0,"time_zone":"UTC","chats":[],"senders":[],"services":[],"dates":[{"date":"2026-02-30","message_count":1}],"media":null}'
      exit 0
    fi
    if [[ "$malformed_kind" == statistics-pipe-holder ]]; then
      sleep 10 &
      printf '%s\n' \
        '{"total_messages":0,"sent_messages":0,"received_messages":0,"time_zone":"UTC","chats":[],"senders":[],"services":[],"dates":[],"media":null}'
      exit 0
    fi
    if [[ "$malformed_kind" == statistics-overflow ]]; then
      printf '{"total_messages":101,"sent_messages":50,"received_messages":51,"time_zone":"UTC","chats":['
      for index in {0..100}; do
        (( index == 0 )) || printf ','
        printf '{"chat_id":%d,"identifier":"chat-%03d","name":"Chat %03d","service":"iMessage","message_count":1}' \
          "$((index + 1))" "$index" "$index"
      done
      printf '],"senders":['
      for index in {0..100}; do
        (( index == 0 )) || printf ','
        printf '{"handle":"sender-%03d","message_count":1}' "$index"
      done
      printf '],"services":['
      for index in {0..100}; do
        (( index == 0 )) || printf ','
        printf '{"service":"service-%03d","message_count":1}' "$index"
      done
      printf '],"dates":['
      for index in {0..100}; do
        (( index == 0 )) || printf ','
        printf '{"date":"%04d-01-01","message_count":1}' "$((1900 + index))"
      done
      printf '],"media":{"total_attachments":101,"total_bytes":101,"types":['
      for index in {0..100}; do
        (( index == 0 )) || printf ','
        printf '{"uti":"uti-%03d","mime_type":"application/x-%03d","attachment_count":1,"total_bytes":1}' \
          "$index" "$index"
      done
      printf '],"chats":['
      for index in {0..100}; do
        (( index == 0 )) || printf ','
        printf '{"chat_id":%d,"identifier":"media-chat-%03d","name":"Media Chat %03d","attachment_count":1,"total_bytes":1}' \
          "$((index + 1))" "$index" "$index"
      done
      printf ']}}\n'
      exit 0
    fi
    printf '%s\n' \
      '{"total_messages":2,"sent_messages":1,"received_messages":1,"time_zone":"UTC","chats":[{"chat_id":42,"identifier":"iMessage;-;+15551234567","name":"Test Chat","service":"iMessage","message_count":2,"account_id":"private-account-id"}],"senders":[{"handle":"+15551234567","message_count":1}],"services":[{"service":"iMessage","message_count":2}],"dates":[{"date":"2026-08-09","message_count":2}],"media":{"total_attachments":1,"total_bytes":123,"types":[{"uti":"public.jpeg","mime_type":"image/jpeg","attachment_count":1,"total_bytes":123,"original_path":"/Users/kleo/secret.jpg"}],"chats":[{"chat_id":42,"identifier":"iMessage;-;+15551234567","name":"Test Chat","attachment_count":1,"total_bytes":123,"account_login":"private@example.test"}]}}'
    ;;
  send)
    has_argument --service "$@" && [[ "$(option_value --service "$@")" == imessage ]] || {
      printf 'unsafe service\n'
      exit 65
    }
    has_argument --no-sms-fallback "$@" || {
      printf 'SMS fallback was not disabled\n'
      exit 65
    }
    if has_argument --file "$@" || has_argument --transport "$@" || has_argument --region "$@"; then
      printf 'unsafe send option\n'
      exit 65
    fi
    if [[ -f "${fixture_prefix}.shared-send-deadline" ]]; then
      sleep 1.25
    fi
    if [[ -f "${fixture_prefix}.send-timeout" ]]; then
      sleep 10
    fi
    printf '%s\n' \
      '{"status":"sent","id":300,"guid":"sent-guid-300","message_id":"sent-guid-300","upstream_private":"must-not-pass-through"}'
    ;;
  *)
    printf 'unsupported fake imsg command: %s\n' "$command_name"
    exit 64
    ;;
esac
