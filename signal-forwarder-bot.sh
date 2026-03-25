#!/usr/bin/env bash
trap '
	echo;echo "signal-forwarder-bot stopped, shutting down...";
	kill "$NC_PID" 2>/dev/null;
	exec 3>&-; exec 4<&-;
	rm -f "$SIGNAL_FIFO_IN" "$SIGNAL_FIFO_OUT";' EXIT
trap 'exit 0' INT TERM

# ================================================
# signal-forwarder-bot
# Forwards all messages from one group to another
# ================================================

SOURCE_GROUP="XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX="
TARGET_GROUP="XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX="
UUID="XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX"
SOCKET="${XDG_RUNTIME_DIR:-$HOME/.local/run}/signal-cli/socket"
IMAGES="${HOME}/.local/share/signal-cli/attachments/"
TIMESTAMPS="${HOME}/.local/share/signal-cli/timestamps.txt"
SIGNATURE="via -kønzi-"

echo "signal-forwarder-bot starting"
if [[ ! -S "$SOCKET" ]]; then
	echo "ERROR: Socket not found at $SOCKET"
	exit 1
fi
echo "Connected to socket, waiting for messages"

json_get() {
	local key=$1
	local json=$2
	[[ ${json} =~ \"$key\":(\"([^\"\\]|\\.)*|[0-9]+|null) ]]
	echo $(echo "${BASH_REMATCH[1]}" | (sed 's/^"//;s/^null$//'))
}

SIGNAL_FIFO_IN=$(mktemp -u)
SIGNAL_FIFO_OUT=$(mktemp -u)
mkfifo "$SIGNAL_FIFO_IN" "$SIGNAL_FIFO_OUT"
nc -U "$SOCKET" <"$SIGNAL_FIFO_IN" >"$SIGNAL_FIFO_OUT" &
NC_PID=$!
exec 3>"$SIGNAL_FIFO_IN"
exec 4<"$SIGNAL_FIFO_OUT"
TO_SIGNAL=3
FROM_SIGNAL=4

receive='{"jsonrpc":"2.0","method":"receive","id":1,"params":{"timeout":1,"maxMessages":1}}'
while true; do
	echo "$receive" >&"$TO_SIGNAL"
	read -r line <&"$FROM_SIGNAL"
	[[ ! "$line" =~ "$SOURCE_GROUP" ]] && { continue; }
	
	quote=$(echo "$line" | grep -oE '"quote":{([^{\[\"]*(({[^}]*})?|(\[[^]]*])?|(\"([^\"\\]|\\.)*\")?))*?}')
	[[ -n $quote ]] && lineWithoutQuote=$(echo "$line" | sed "s[$(echo "$quote" | sed 's/[\[]/\\&/g')[[") || lineWithoutQuote=$line
	[[ ${lineWithoutQuote} =~ '"message":"'(([^\"\\]|\\.)*) ]] && MESSAGE="${BASH_REMATCH[1]}" || MESSAGE=""
	[[ ${lineWithoutQuote} =~ '"attachments":['([^]]*) ]] && attachments="${BASH_REMATCH[1]}" || attachments=""

	payload=""
	if [[ -n "$MESSAGE" || -n "$attachments" ]]; then
		sender=$(json_get "sourceName" "$lineWithoutQuote")
		MESSAGE='"message":"'$MESSAGE$([ -n "$MESSAGE" ] && echo '\n\n')$sender' '$SIGNATURE'"'
		
		STYLES=""
		if [[ ${lineWithoutQuote} =~ '"textStyles":['([^]]*) ]]; then
			styles=$(echo "${BASH_REMATCH[1]}" | grep -oE '{"style":[^}]*}')
			STYLES='"textStyle":['
			for style in $styles
			do
				STYLES="${STYLES}\"$(json_get "start" "$style"):$(json_get "length" "$style"):$(json_get "style" "$style")\", "
			done
			STYLES=${STYLES%, }]
		fi
		
		MENTIONS=""
		if [[ ${lineWithoutQuote} =~ '"mentions":['([^]]*) ]]; then
			mentions=$(echo  "${BASH_REMATCH[1]}" | grep -oE '{"name":[^}]*}')
			MENTIONS='"mentions":['
			for mention in $mentions
			do
				MENTIONS="${MENTIONS}\"$(json_get "start" "$mention"):$(json_get "length" "$mention"):$(json_get "uuid" "$mention")\","
			done
			MENTIONS=${MENTIONS%,}]
		fi
	
		PREVIEW=""
		if [[ ${lineWithoutQuote} =~ '"previews":['([^]]*) ]]; then
			preview="${BASH_REMATCH[1]}"
			previewImage=$(json_get "id" "$preview")
			PREVIEW='"previewUrl":"'$(json_get "url" "$preview")'","previewTitle":"'$(json_get "title" "$preview")'","previewDescription":"'$(json_get "description" "$preview")'"'$([ -n "$previewImage" ] && echo ',"previewImage":"'$IMAGES$previewImage'"')
		fi
	
		ATTACHMENTS=""
		if [[ -n "$attachments" ]]; then
			attachmentIds=($(echo "$attachments" | grep -oE '"id":"(([^\"\\]|\\.)*)"' | sed 's/^"id":"//;s/"$//'))
			CONTENT_TYPES=($(echo "$attachments" | grep -oE '"contentType":"(([^\"\\]|\\.)*)"' | sed 's/^"contentType":"//;s/"$//'))
			ATTACHMENTS='"attachment":['			
			for i in ${!attachmentIds[@]}
			do
				ATTACHMENTS=$ATTACHMENTS'"data:'${CONTENT_TYPES[$i]}';base64,'$(cat $IMAGES${attachmentIds[$i]} | base64)'",'
			done
			ATTACHMENTS=${ATTACHMENTS%,}]
		fi
	
		QUOTE=""
		if [[ -n "$quote" ]]; then
			timestamp=$(grep $(json_get "id" "$quote") $TIMESTAMPS | head -1 | sed 's/^.* //')
			[[ ${quote} =~ '"thumbnail":{'([^}]*) ]] && thumbnail="${BASH_REMATCH[1]}" || thumbnail=""
			[[ -n "$thumbnail" ]] && thumbnail=$(json_get "contentType" "$thumbnail")':thumbnail:'$IMAGES$(json_get "id" "$thumbnail") || thumbnail=""
			QUOTE='"quoteTimestamp":'$timestamp',"quoteAuthor":"'$UUID'"'$([ -n "$thumbnail" ] && echo ',"quoteAttachment":"'$thumbnail'"')
		fi
		
		EDIT=""
		if [[ ${lineWithoutQuote} =~ '"editMessage":{'([^}]*) ]]; then
			timestamp=$(grep $(json_get "targetSentTimestamp" "${BASH_REMATCH[1]}") $TIMESTAMPS | head -1 | sed 's/^.* //')
			EDIT='"editTimestamp":'$timestamp
		fi
		
		payload='{"jsonrpc":"2.0","method":"send","id":1,"params":{"groupId":"'$TARGET_GROUP'",'$MESSAGE$([ -n "$STYLES" ] && echo ,$STYLES)$([ -n "$MENTIONS" ] && echo ,$MENTIONS)$([ -n "$PREVIEW" ] && echo ,$PREVIEW)$([ -n "$ATTACHMENTS" ] && echo ,$ATTACHMENTS)$([ -n "$QUOTE" ] && echo ,$QUOTE)$([ -n "$EDIT" ] && echo ,$EDIT)'}}'
		echo "$payload" >&"$TO_SIGNAL"
		read -r response <&"$FROM_SIGNAL"

		timestamp_in=$(json_get "timestamp" "$line")
		timestamp_out=$(json_get "timestamp" "$response")
		echo $timestamp_in $timestamp_out >> $TIMESTAMPS
	else
		if [[ ${lineWithoutQuote} =~ '"remoteDelete":{'([^}]*) ]]; then
			timestamp=$(grep $(json_get "timestamp" "${BASH_REMATCH[1]}") $TIMESTAMPS | head -1 | sed 's/^.* //')
			payload='{"jsonrpc":"2.0","method":"remoteDelete","id":1,"params":{"groupId":"'$TARGET_GROUP'","targetTimestamp":'$timestamp'}}'
			echo "$payload" >&"$TO_SIGNAL"
			read -r response <&"$FROM_SIGNAL"
		fi
	fi
	if [[ -n $payload ]]; then
		echo "----------"
		echo "$line"
		echo
		echo $(echo "$payload" | sed -E 's/(base64,[^"]{0,30})[^"]*"/\1..."/g')
		echo
		echo $(echo "$response" | sed -E 's/("results":\[(\{[^}]*}[^}]*},?){0,2})[^]]*/\1'$([[ $(echo "$response" | grep -o "recipientAddress" | wc -l) -gt 2 ]] && echo "...")'/g')
	fi
done

echo
echo "ERROR: Something went wrong?!"
exit 1
