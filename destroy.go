package vm

import (
	"fmt"
	"strings"

	"github.com/libvirt/libvirt-go"
)

// Destroy stops and undefines a domain by name or id. If force is true, the
// domain is destroyed without prompting for confirmation.
func Destroy(name string, id int, force bool) error {
	conn, err := libvirt.NewConnect("")
	if err != nil {
		return err
	}

	if len(name) > 0 && id > 0 {
		return fmt.Errorf("conflicting arguments: name, id")
	}

	var dom *libvirt.Domain
	if name != "" {
		dom, err = conn.LookupDomainByName(name)
		if err != nil {
			return err
		}
	} else if id > 0 {
		dom, err = conn.LookupDomainById(uint32(id))
		if err != nil {
			return err
		}
	} else {
		return fmt.Errorf("conflicting arguments: name, id")
	}
	defer dom.Free()

	name, err = dom.GetName()
	if err != nil {
		return err
	}

	if !force {
		fmt.Printf("Are you sure you wish to destroy %v? (y/N) ", name)
		var response string
		fmt.Scan(&response)
		response = strings.ToLower(strings.TrimSpace(response))
		if response != "y" {
			return nil
		}
	}

	state, _, err := dom.GetState()
	if err != nil {
		return err
	}
	if state == libvirt.DOMAIN_RUNNING {
		err = dom.Destroy()
		if err != nil {
			return err
		}
	}

	err = dom.Undefine()
	if err != nil {
		return err
	}

	return nil
}
