package main

import (
	"os"

	"silen/cres/internal/cli"
)

func main() {
	os.Exit(cli.Run(os.Args[1:]))
}
