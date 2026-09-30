.PHONY: app run install clean

app:
	./scripts/build-app.sh

run: app
	open build/Voicedic.app

install: app
	-osascript -e 'quit app "Voicedic"'
	while pgrep -xq Voicedic; do sleep 0.2; done
	rm -rf /Applications/Voicedic.app
	cp -R build/Voicedic.app /Applications/
	open /Applications/Voicedic.app

clean:
	rm -rf build .build
