package textkit

import (
	"context"
	"net/url"
)

// ── customers ───────────────────────────────────────────────────────────────

// CustomersService manages the businesses you send on behalf of (for
// platforms). Entirely optional.
type CustomersService struct{ c *Client }

// CreateCustomerParams is what Customers.Create takes. Every field is optional.
type CreateCustomerParams struct {
	Name       string
	ExternalID string
	Metadata   map[string]string
}

// Create adds a customer. Not retried.
func (s *CustomersService) Create(ctx context.Context, p *CreateCustomerParams) (*Customer, error) {
	body := map[string]any{}
	if p != nil {
		putString(body, "name", p.Name)
		putString(body, "external_id", p.ExternalID)
		if len(p.Metadata) > 0 {
			body["metadata"] = p.Metadata
		}
	}
	out := new(Customer)
	_, err := s.c.do(ctx, request{method: "POST", path: "/customers", body: body}, out)
	return result(out, err)
}

// Get fetches one customer.
func (s *CustomersService) Get(ctx context.Context, id string) (*Customer, error) {
	out := new(Customer)
	_, err := s.c.do(ctx, request{method: "GET", path: "/customers/" + pathEscape(id), retryable: true}, out)
	return result(out, err)
}

// UpdateCustomerParams changes only the fields that are Set; Null clears one.
// Metadata replaces the whole object.
type UpdateCustomerParams struct {
	Name       Optional[string]
	ExternalID Optional[string]
	Metadata   Optional[map[string]string]
}

// Update changes a customer.
func (s *CustomersService) Update(ctx context.Context, id string, p *UpdateCustomerParams) (*Customer, error) {
	body := map[string]any{}
	if p != nil {
		p.Name.put(body, "name")
		p.ExternalID.put(body, "external_id")
		p.Metadata.put(body, "metadata")
	}
	out := new(Customer)
	_, err := s.c.do(ctx, request{method: "PATCH", path: "/customers/" + pathEscape(id), body: body, retryable: true}, out)
	return result(out, err)
}

// Delete removes a customer. Its numbers stay yours, unassigned.
func (s *CustomersService) Delete(ctx context.Context, id string) (*Deleted, error) {
	out := new(Deleted)
	_, err := s.c.do(ctx, request{method: "DELETE", path: "/customers/" + pathEscape(id)}, out)
	return result(out, err)
}

// ListCustomersParams filters Customers.List.
type ListCustomersParams struct {
	Limit      int
	Cursor     string
	ExternalID string
}

// List returns one page of customers.
func (s *CustomersService) List(ctx context.Context, p *ListCustomersParams) (*Page[Customer], error) {
	if p == nil {
		p = &ListCustomersParams{}
	}
	q := url.Values{"limit": {intString(p.Limit)}, "cursor": {p.Cursor}, "external_id": {p.ExternalID}}
	out := new(Page[Customer])
	_, err := s.c.do(ctx, request{method: "GET", path: "/customers", query: q, retryable: true}, out)
	return result(out, err)
}

// ListAll walks every customer. p.Cursor is ignored.
func (s *CustomersService) ListAll(ctx context.Context, p *ListCustomersParams) *Iter[Customer] {
	base := ListCustomersParams{}
	if p != nil {
		base = *p
	}
	return newIter(ctx, func(ctx context.Context, cursor string) (*Page[Customer], error) {
		q := base
		q.Cursor = cursor
		return s.List(ctx, &q)
	})
}

// CustomerUsageParams is a UTC date range, "YYYY-MM-DD"; default this month to date.
type CustomerUsageParams struct {
	Start string
	End   string
}

// Usage returns a customer's usage. Follows the key: test keys report
// sandbox traffic, live keys live.
func (s *CustomersService) Usage(ctx context.Context, id string, p *CustomerUsageParams) (*CustomerUsage, error) {
	q := url.Values{}
	if p != nil {
		q.Set("start", p.Start)
		q.Set("end", p.End)
	}
	out := new(CustomerUsage)
	_, err := s.c.do(ctx, request{method: "GET", path: "/customers/" + pathEscape(id) + "/usage", query: q, retryable: true}, out)
	return result(out, err)
}

// ── contacts ────────────────────────────────────────────────────────────────

// ContactsService is the address book. One contact per phone number; tags
// double as broadcast audiences.
type ContactsService struct{ c *Client }

// ContactParams is one contact for Contacts.Upsert and Contacts.Import.
type ContactParams struct {
	PhoneNumber string            `json:"phone_number"`
	Name        string            `json:"name,omitempty"`
	Tags        []string          `json:"tags,omitempty"`
	Fields      map[string]string `json:"fields,omitempty"`
	Notes       string            `json:"notes,omitempty"`
}

// Upsert creates a contact, or updates the one that already has this
// number. Values you leave out are kept; tags are added, never removed.
func (s *ContactsService) Upsert(ctx context.Context, p *ContactParams) (*Contact, error) {
	if p == nil {
		p = &ContactParams{}
	}
	out := new(Contact)
	_, err := s.c.do(ctx, request{method: "POST", path: "/contacts", body: p, retryable: true}, out)
	return result(out, err)
}

// Import upserts up to 500 contacts in one call.
func (s *ContactsService) Import(ctx context.Context, contacts []ContactParams) (*ContactImport, error) {
	if contacts == nil {
		contacts = []ContactParams{}
	}
	out := new(ContactImport)
	_, err := s.c.do(ctx, request{method: "POST", path: "/contacts/import", body: map[string]any{"contacts": contacts}, retryable: true}, out)
	return result(out, err)
}

// Consent returns consent for a phone number; the same as Consent.Get.
func (s *ContactsService) Consent(ctx context.Context, phoneNumber string) (*ConsentDetail, error) {
	return s.c.Consent.Get(ctx, phoneNumber)
}

// ContactBulkParams is what Contacts.Bulk takes.
type ContactBulkParams struct {
	Action string   // add_tags | remove_tags | delete
	IDs    []string // up to 500 contact ids
	Tags   []string // for add_tags and remove_tags
}

// Bulk applies one action to up to 500 contacts. Not retried.
func (s *ContactsService) Bulk(ctx context.Context, p *ContactBulkParams) (*ContactBulk, error) {
	if p == nil {
		p = &ContactBulkParams{}
	}
	ids := p.IDs
	if ids == nil {
		ids = []string{}
	}
	body := map[string]any{"action": p.Action, "ids": ids}
	if p.Tags != nil {
		body["tags"] = p.Tags
	}
	out := new(ContactBulk)
	_, err := s.c.do(ctx, request{method: "POST", path: "/contacts/bulk", body: body}, out)
	return result(out, err)
}

// Get fetches one contact.
func (s *ContactsService) Get(ctx context.Context, id string) (*Contact, error) {
	out := new(Contact)
	_, err := s.c.do(ctx, request{method: "GET", path: "/contacts/" + pathEscape(id), retryable: true}, out)
	return result(out, err)
}

// UpdateContactParams changes only the fields that are Set. Tags and Fields
// replace what is stored; Null clears Name or Notes.
type UpdateContactParams struct {
	PhoneNumber Optional[string]
	Name        Optional[string]
	Tags        Optional[[]string]
	Fields      Optional[map[string]string]
	Notes       Optional[string]
}

// Update changes a contact.
func (s *ContactsService) Update(ctx context.Context, id string, p *UpdateContactParams) (*Contact, error) {
	body := map[string]any{}
	if p != nil {
		p.PhoneNumber.put(body, "phone_number")
		p.Name.put(body, "name")
		p.Tags.put(body, "tags")
		p.Fields.put(body, "fields")
		p.Notes.put(body, "notes")
	}
	out := new(Contact)
	_, err := s.c.do(ctx, request{method: "PATCH", path: "/contacts/" + pathEscape(id), body: body, retryable: true}, out)
	return result(out, err)
}

// Delete removes a contact.
func (s *ContactsService) Delete(ctx context.Context, id string) (*Deleted, error) {
	out := new(Deleted)
	_, err := s.c.do(ctx, request{method: "DELETE", path: "/contacts/" + pathEscape(id)}, out)
	return result(out, err)
}

// ListContactsParams filters Contacts.List.
type ListContactsParams struct {
	Limit  int
	Cursor string
	Tag    string
	// PhoneNumber finds the one contact holding it.
	PhoneNumber string
}

// List returns one page of contacts, newest first.
func (s *ContactsService) List(ctx context.Context, p *ListContactsParams) (*Page[Contact], error) {
	if p == nil {
		p = &ListContactsParams{}
	}
	q := url.Values{"limit": {intString(p.Limit)}, "cursor": {p.Cursor}, "tag": {p.Tag}, "phone_number": {p.PhoneNumber}}
	out := new(Page[Contact])
	_, err := s.c.do(ctx, request{method: "GET", path: "/contacts", query: q, retryable: true}, out)
	return result(out, err)
}

// ListAll walks every contact. p.Cursor is ignored.
func (s *ContactsService) ListAll(ctx context.Context, p *ListContactsParams) *Iter[Contact] {
	base := ListContactsParams{}
	if p != nil {
		base = *p
	}
	return newIter(ctx, func(ctx context.Context, cursor string) (*Page[Contact], error) {
		q := base
		q.Cursor = cursor
		return s.List(ctx, &q)
	})
}
