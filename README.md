# signal-forwarder-bot
Simple bash script to forward all messages from one group to another with signal-cli.

We have a signal group in Switzerland for punk concerts (kønzi). It reached the limit of 1000 members.
The idea was for a simple signal bot that copies every new message in kønzi to another group (kønzi2).

It forwards messages with styles, mentions, attachments, link previews and quotes but drops reactions.
It handles edited and deleted messages.

It's crudely ape coded in bash with only signal-cli, nc, grep and sed as dependencies.
The json parsing is very ugly, but works.

It uses a socket: start signal-cli with daemon --socket, start this script in another shell.
SOURCE_GROUP and TAGET_GROUP can be obtained with signal-cli listGroups.
UUID is your uuid and is used to quote messages (replies).
SOCKET path is MacOS specific, use what fits your OS.
IMAGES is the signal-cli attachments cache.
TIMESTAMPS has to be created first and is used for quoted, edited or deleted messages.
