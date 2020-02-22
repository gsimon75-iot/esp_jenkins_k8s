#!/usr/bin/env bash
# Run a playbook and record its output to a log file as well

if [ "$1" = "-l" ]; then
	shift
	do_log=1
fi

arg1dotless="${1%.}"
if [ "$1" != "$arg1dotless" ]; then
	shift
	set -- "$arg1dotless.yaml" "$@"
fi

arg1yamlless="${1%.yaml}"
if [ "$1" == "$arg1yamlless" ]; then
	shift
	set -- "$arg1yamlless.yaml" "$@"
fi


if [ -n "$do_log" ]; then
	LOGFILE="${1%.yaml}.log"
	stdbuf -oL ansible-playbook -i inventory.gcp_compute.yaml "$@" 2>&1 | awk '{print strftime("%H:%M:%S ") $0; fflush();}' | stdbuf -oL tee "$LOGFILE"
else
	ansible-playbook -i inventory.gcp_compute.yaml "$@"
fi
