# make        → kwg (ARMv7 static binary)
# make plugin → dist/kwg.koplugin.zip (KOReader plugin incl. binary + watchdog)
GOFLAGS_ARM = CGO_ENABLED=0 GOOS=linux GOARCH=arm GOARM=7

kwg: main.go go.mod go.sum
	$(GOFLAGS_ARM) go build -trimpath -ldflags="-s -w" -o kwg .

plugin: kwg
	rm -rf dist && mkdir -p dist/kwg.koplugin
	cp kwg.koplugin/_meta.lua kwg.koplugin/main.lua kwg kwg-loop.sh dist/kwg.koplugin/
	chmod 755 dist/kwg.koplugin/kwg dist/kwg.koplugin/kwg-loop.sh
	cd dist && zip -qr kwg.koplugin.zip kwg.koplugin
	cd dist && cp ../kwg . && sha256sum kwg kwg.koplugin.zip > SHA256SUMS

clean:
	rm -rf kwg dist

.PHONY: plugin clean
