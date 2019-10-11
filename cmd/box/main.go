package main

import (
	"log"
	"os"

	"github.com/subpop/box"

	"github.com/urfave/cli"
)

func main() {
	var err error
	var app *cli.App

	app = cli.NewApp()
	app.Name = "box"
	app.Commands = []cli.Command{
		{
			Name: "create",
			Action: func(c *cli.Context) error {
				return box.Create(c.String("name"), c.String("image"))
			},
			Flags: []cli.Flag{
				cli.StringFlag{
					Name: "n,name",
				},
				cli.StringFlag{
					Name:     "i,image",
					Required: true,
				},
			},
		},
		{
			Name: "list",
			Action: func(c *cli.Context) error {
				active := true
				inactive := false

				if c.Bool("inactive") {
					active = false
					inactive = true
				}

				if c.Bool("all") {
					active = true
					inactive = true
				}

				return box.List(active, inactive)
			},
			Flags: []cli.Flag{
				cli.BoolFlag{
					Name: "all",
				},
				cli.BoolFlag{
					Name: "inactive",
				},
			},
		},
		{
			Name: "destroy",
			Action: func(c *cli.Context) error {
				return box.Destroy(c.String("name"), c.Int("id"), c.Bool("force"))
			},
			Flags: []cli.Flag{
				cli.StringFlag{
					Name:     "name,n",
					Required: true,
				},
				cli.BoolFlag{
					Name: "force,f",
				},
			},
		},
		{
			Name: "up",
			Action: func(c *cli.Context) error {
				return box.Up(c.String("name"))
			},
			Flags: []cli.Flag{
				cli.StringFlag{
					Name:     "name,n",
					Required: true,
				},
			},
		},
		{
			Name: "down",
			Action: func(c *cli.Context) error {
				return box.Down(c.String("name"), c.Int("id"), c.Bool("force"))
			},
			Flags: []cli.Flag{
				cli.StringFlag{
					Name:     "name,n",
					Required: true,
				},
				cli.BoolFlag{
					Name: "force",
				},
			},
		},
		{
			Name: "connect",
			Action: func(c *cli.Context) error {
				return box.Connect(c.String("name"), c.String("mode"), c.String("user"))
			},
			Flags: []cli.Flag{
				cli.StringFlag{
					Name:     "name,n",
					Required: true,
				},
				cli.StringFlag{
					Name:  "mode,m",
					Value: "ssh",
				},
				cli.StringFlag{
					Name:  "user,u",
					Value: "root",
				},
			},
		},
		{
			Name: "image",
			Subcommands: []cli.Command{
				{
					Name: "list",
					Action: func(c *cli.Context) error {
						return box.ImageList()
					},
				},
				{
					Name: "sync",
					Action: func(c *cli.Context) error {
						return box.ImageSync()
					},
				},
				{
					Name: "info",
					Action: func(c *cli.Context) error {
						return box.ImageInfo(c.String("name"), c.String("arch"))
					},
					Flags: []cli.Flag{
						cli.StringFlag{
							Name:     "name,n",
							Required: true,
						},
						cli.StringFlag{
							Name:  "arch,a",
							Value: "x86_64",
						},
					},
				},
				{
					Name: "get",
					Action: func(c *cli.Context) error {
						return box.ImageGet(c.String("name"), c.String("arch"))
					},
					Flags: []cli.Flag{
						cli.StringFlag{
							Name:     "n,name",
							Required: true,
						},
						cli.StringFlag{
							Name:  "a,arch",
							Value: "x86_64",
						},
					},
				},
				{
					Name: "remove",
					Action: func(c *cli.Context) error {
						return box.ImageRemove(c.String("name"), c.Bool("force"))
					},
					Flags: []cli.Flag{
						cli.StringFlag{
							Name:     "n,name",
							Required: true,
						},
						cli.BoolFlag{
							Name: "force",
						},
					},
				},
			},
		},
	}

	err = app.Run(os.Args)
	if err != nil {
		log.Fatal(err)
	}
}
