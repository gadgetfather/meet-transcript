.PHONY: setup run icon dmg-lite dmg-full dmg-both

setup:
	./scripts/setup.sh

run:
	./scripts/run.sh

icon:
	./scripts/generate_app_icon.sh

dmg-lite:
	./scripts/build_dmg.sh --variant lite

dmg-full:
	./scripts/build_dmg.sh --variant full --model base.en

dmg-both:
	./scripts/build_dmg.sh --variant both --model base.en
