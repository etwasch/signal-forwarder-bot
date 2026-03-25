# signal-forwarder-bot
Simple bash script to forward all messages from one group to another with signal-cli.

We have a signal group in Switzerland for punk concerts (kønzi). It reached the limit of 1000 members.<br>
The idea was for a simple signal bot that copies every new message in kønzi to another group (kønzi2).<br>

It forwards messages with styles, mentions, attachments, link previews and quotes but drops reactions.<br>
It handles edited and deleted messages.

It's crudely ape coded in bash with only signal-cli, nc, grep and sed as dependencies.<br>
Netcat must have the -U option, replace it with socat or whatever's available if necessary.<br>
The json parsing is fast and ugly but works.

It uses a unix socket: start signal-cli with daemon --socket --receive-mode=manual.<br>
Then start this script in another shell.

SOURCE_GROUP and TAGET_GROUP can be obtained with signal-cli listGroups.<br>
UUID is your uuid and is used to quote messages (replies). Get it from the accounts.json file in the signal-cli data folder.<br>
SOCKET path is MacOS specific, use what fits your OS. signal-cli uses XDG_RUNTIME_DIR, set it in the environment.<br>
IMAGES is the signal-cli attachments cache.<br>
TIMESTAMPS has to be created first and is used to quote, edit or delete messages.<br>
