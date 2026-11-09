# Per-question answer flags (--answer, --answer-text, --answers-file). Sourced by aiur-engine.sh.
# Shared by executor-answer, operator-relay-answer and `aiur command ID --relayed`;
# QA_EXTRA is how many extra arguments the flag consumed.
# @cli-reference aiur operator-relay-answer ID --answer Q=ID --answer-text Q=TEXT --answers-file PATH | Per-question answers for a multi-question Command, with the same rules as `executor-answer`. | aiur operator-relay-answer dec_123 --expected-version 1 --answer scope=core --answer order=last --quote "core, last" --relayed-by exec-1 --idempotency-key relay-1
question_answer_flag() {
  local flag="${1%%=*}" value
  QA_EXTRA=0
  case "$flag" in --answer | --answer-text | --answers-file) ;; *) return 1 ;; esac
  if [ "$flag" = "$1" ]; then
    [ "$#" -gt 1 ] || { echo "aiur: $flag requires a value" >&2; exit 64; }
    value="$2"; QA_EXTRA=1
  else
    value="${1#*=}"
  fi
  [ -n "$value" ] || { echo "aiur: $flag requires a value" >&2; exit 64; }
  case "$flag" in
    --answer) QA_ANSWERS="${QA_ANSWERS:-}${QA_ANSWERS:+, }Base.decode64!(\"$(encode_control_value "$value")\")" ;;
    --answer-text) QA_TEXTS="${QA_TEXTS:-}${QA_TEXTS:+, }Base.decode64!(\"$(encode_control_value "$value")\")" ;;
    --answers-file)
      # Read on the caller's machine; the daemon may run elsewhere.
      [ -f "$value" ] && [ -r "$value" ] || { echo "aiur: --answers-file cannot read $value" >&2; exit 64; }
      # The file travels base64-encoded inside one control RPC argument.
      [ "$(wc -c < "$value")" -le 65536 ] || { echo "aiur: --answers-file $value is larger than 65536 bytes" >&2; exit 64; }
      QA_FILE="$(cat -- "$value")" ;;
  esac
}

question_answers_given() {
  [ -n "${QA_ANSWERS:-}${QA_TEXTS:-}${QA_FILE:-}" ]
}

question_answer_argument() {
  local out=""
  [ -z "${QA_ANSWERS:-}" ] || out="$out, answers: [$QA_ANSWERS]"
  [ -z "${QA_TEXTS:-}" ] || out="$out, answer_texts: [$QA_TEXTS]"
  [ -z "${QA_FILE:-}" ] || out="$out, answers_json: Base.decode64!(\"$(encode_control_value "$QA_FILE")\")"
  printf '%s' "$out"
}
