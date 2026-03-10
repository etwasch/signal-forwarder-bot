#!/usr/bin/env bash

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

echo "signal-forwarder-bot starting"

if [[ ! -S "$SOCKET" ]]; then
	echo "ERROR: Socket not found at $SOCKET"
	exit 1
fi
echo "Connected to socket, waiting for messages"

json_get() {
	local key=$1
	local json=$2
	local string_regex='"([^"\]|\\.)*"'
	local number_regex='-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?'
	local value_regex="${string_regex}|${number_regex}|true|false|null"
	local pair_regex="\"${key}\"[[:space:]]*:[[:space:]]*(${value_regex})"

	[[ ${json} =~ ${pair_regex} ]]
	echo $(echo "${BASH_REMATCH[1]}" | (sed 's/^"//;s/"$//;s/^null//'))
}

rpc_call() {
	local json=$1
	echo $(echo "$json" | nc -U "$SOCKET" | head -1)
}

nc -U "$SOCKET" | while IFS= read -r line; do
	[[ -z "$line" ]] && continue
	echo "$line" | grep -q '"envelope":' || { continue; }
	echo "$line" | grep -q "$SOURCE_GROUP" || { continue; }
	
	lineWithoutQuote=$(echo "$line" | sed 's/quote[^}]*}//')
	MESSAGE=$(json_get "message" "$lineWithoutQuote")
	attachments=$(echo "$lineWithoutQuote" | grep -oE '"attachments":\[[^]]*\]' | sed 's/"attachments":\[\]//')

	if [[ -n "$MESSAGE" || -n "$attachments" ]]; then
		sender=$(json_get "sourceName" "$lineWithoutQuote")
		MESSAGE='"message":"'$MESSAGE$([ -n "$MESSAGE" ] && echo '\n\n')$sender' via -kønzi-"'
		
		STYLES=""
		styles=$(echo "$lineWithoutQuote" | grep -oE '"textStyles":\[[^]]*\]')
		if [[ -n "$styles" ]]; then
			styles=$(echo "$styles" | grep -oE '{"style":[^}]*}')
			STYLES='"textStyle":['
			for style in $styles
			do
				STYLES="${STYLES}\"$(json_get "start" "$style"):$(json_get "length" "$style"):$(json_get "style" "$style")\", "
			done
			STYLES=${STYLES%, }]
		fi
		
		MENTIONS=""
		mentions=$(echo "$lineWithoutQuote" | grep -oE '"mentions":\[[^]]*\]')
		if [[ -n "$mentions" ]]; then
			mentions=$(echo "$mentions" | grep -oE '{"name":[^}]*}')
			MENTIONS='"mentions":['
			for mention in $mentions
			do
				MENTIONS="${MENTIONS}\"$(json_get "start" "$mention"):$(json_get "length" "$mention"):$(json_get "uuid" "$mention")\","
			done
			MENTIONS=${MENTIONS%,}]
		fi
	
		PREVIEW=""
		preview=$(echo "$lineWithoutQuote" | grep -oE '"previews":\[[^]]*\]')
		if [[ -n "$preview" ]]; then
			previewImage=$(json_get "id" $(echo "$preview" | grep -oE '"image":{[^}]*}'))
			PREVIEW='"previewUrl":"'$(json_get "url" "$preview")'","previewTitle":"'$(json_get "title" "$preview")'","previewDescription":"'$(json_get "description" "$preview")'"'$([ -n "$previewImage" ] && echo ',"previewImage":"'$IMAGES$previewImage'"')
		fi
	
		ATTACHMENTS=""
		attachmentIds=$(echo "$attachments" | grep -oE '"id":"(([^\"\]|\\.)*)"' | sed 's/"//g;s/id://g')
		CONTENT_TYPES=$(echo "$attachments" | grep -oE '"contentType":"(([^\"\]|\\.)*)"' | sed 's/"//g;s/contentType://g')
		CONTENT_TYPES=($CONTENT_TYPES)
		if [[ -n "$attachmentIds" ]]; then
			ATTACHMENTS='"attachment":['
			i=0
			for id in $attachmentIds
			do
				response=$(rpc_call '{"jsonrpc":"2.0","method":"getAttachment","id":1,"params":{"id":"'$id'"}}')
				attachment=$(json_get "data" "$response")
				ATTACHMENTS="${ATTACHMENTS}\"data:${CONTENT_TYPES[$i]};base64,$attachment\","
				((i++))
			done
			ATTACHMENTS=${ATTACHMENTS%,}]
		fi
	
		QUOTE=""
		quote=$(echo "$line" | grep -oE '"quote":{[^}]*}')
		if [[ -n "$quote" ]]; then
			timestamp=$(grep $(json_get "id" "$quote") $TIMESTAMPS | head -1 | sed 's/^.* //')
			thumbnail=$(echo "$quote" | grep -oE '"thumbnail":{[^}]*\}')
			[[ -n "$thumbnail" ]] && thumbnail=$(json_get "contentType" "$thumbnail")':thumbnail:'$IMAGES$(json_get "id" "$thumbnail")
			QUOTE='"quoteTimestamp":'$timestamp',"quoteAuthor":"'$UUID'"'$([ -n "$thumbnail" ] && echo ',"quoteAttachment":"'$thumbnail'"')
		fi
		
		EDIT=""
		editMessage=$(echo "$lineWithoutQuote" | grep -oE '"editMessage":{[^}]*}')
		if [[ -n "$editMessage" ]]; then
			timestamp=$(grep $(json_get "targetSentTimestamp" "$editMessage") $TIMESTAMPS | head -1 | sed 's/^.* //')
			EDIT='"editTimestamp":'$timestamp
		fi
		
		payload='{"jsonrpc":"2.0","method":"send","id":1,"params":{"groupId":"'$TARGET_GROUP'",'$MESSAGE$([ -n "$STYLES" ] && echo ,$STYLES)$([ -n "$MENTIONS" ] && echo ,$MENTIONS)$([ -n "$PREVIEW" ] && echo ,$PREVIEW)$([ -n "$ATTACHMENTS" ] && echo ,$ATTACHMENTS)$([ -n "$QUOTE" ] && echo ,$QUOTE)$([ -n "$EDIT" ] && echo ,$EDIT)'}}'
		response=$(rpc_call "$payload")

		timestamp_in=$(json_get "timestamp" "$line")
		timestamp_out=$(json_get "timestamp" "$response")
		echo $timestamp_in $timestamp_out >> $TIMESTAMPS

		#echo $line
		#echo ""	
		#echo $payload
		#echo ""
		#echo $response
		#echo "----------"
	else
		remoteDelete=$(echo "$lineWithoutQuote" | grep -oE '"remoteDelete":{[^}]*}')
		if [[ -n "$remoteDelete" ]]; then
			timestamp=$(grep $(json_get "timestamp" "$remoteDelete") $TIMESTAMPS | head -1 | sed 's/^.* //')
			payload='{"jsonrpc":"2.0","method":"remoteDelete","id":1,"params":{"groupId":"'$TARGET_GROUP'","targetTimestamp":'$timestamp'}}'
			response=$(rpc_call "$payload")

			#echo $line
			#echo ""	
			#echo $payload
			#echo ""
			#echo $response
			#echo "----------"
		fi
	fi
done

echo ""
echo "ERROR: nc exited. daemon stopped or socket lost."
