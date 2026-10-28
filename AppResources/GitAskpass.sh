#!/bin/sh
case "$1" in
  *Username*|*username*) printf '%s\n' "$CODEFLIGHT_AUTH_USER" ;;
  *Password*|*password*) printf '%s\n' "$CODEFLIGHT_AUTH_SECRET" ;;
  *) exit 1 ;;
esac
