# Agent instructions

## After every turn

When a turn changes the app, finish it by:

1. Installing the new copy with `make install`. It builds `build/Voicedic.app`, quits the running
   Voicedic, replaces `/Applications/Voicedic.app`, and launches the new one.
2. Committing the changes, split into logical commits.
