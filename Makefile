# Run the formatter manually
format:
	# apple/swift-format
	swift-format ./Sources ./Tests -i -p -r --configuration .swift-format

# Release: tag, push, and publish a GitHub release, e.g. `make release VERSION=1.0.0`
release:
	./scripts/release.sh $(VERSION)
