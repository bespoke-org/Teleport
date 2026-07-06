## ADDED Requirements

### Requirement: User can maintain an ordered list of split-tunnel rules
The system SHALL allow the user to add, edit, reorder, enable, disable, and remove destination-based split-tunnel rules, each matching either a domain or an IP/CIDR value and each carrying an action of direct, proxy, or block, and SHALL persist this list across app relaunches.

#### Scenario: Add a domain rule
- **WHEN** the user enters a hostname-shaped value in the split-tunnel add-rule field, selects an action, and commits it
- **THEN** the system classifies it as a domain rule, saves it with the selected action as enabled by default, and shows it in the rule list

#### Scenario: Add an IP/CIDR rule
- **WHEN** the user enters a valid IPv4/IPv6 literal or CIDR value in the split-tunnel add-rule field, selects an action, and commits it
- **THEN** the system classifies it as an IP rule, saves it with the selected action as enabled by default, and shows it in the rule list

#### Scenario: Reject an invalid rule value
- **WHEN** the user commits a value that is neither a valid domain shape nor a valid IP/CIDR
- **THEN** the system shows an inline validation error and does not add or persist a rule

#### Scenario: Change a rule's action
- **WHEN** the user changes a saved rule's action between direct, proxy, and block
- **THEN** the system persists the new action for that rule and uses it for subsequent tunnel routing generation

#### Scenario: Reorder rules
- **WHEN** the user drags a rule to a new position in the list
- **THEN** the system persists the new evaluation order for that rule relative to the others

#### Scenario: Disable a rule without removing it
- **WHEN** the user turns off a rule's enable toggle
- **THEN** the system keeps the rule in the persisted list but excludes it from tunnel routing generation until re-enabled

#### Scenario: Remove a rule
- **WHEN** the user deletes a rule from the list
- **THEN** the system removes it from the persisted list and from subsequent tunnel routing generation

#### Scenario: Restore rules after relaunch
- **WHEN** the application restarts after split-tunnel rules were previously saved
- **THEN** the system restores the full rule list with each rule's kind, value, order, and enable state unchanged

### Requirement: Split tunneling can be enabled or disabled independently of the saved rule list
The system SHALL provide a single toggle that enables or disables split-tunnel routing generation as a whole without discarding the saved rule list.

#### Scenario: Disable split tunneling while keeping rules saved
- **WHEN** the user turns off the split-tunneling toggle
- **THEN** the system stops generating split-tunnel routing rules for the VPN tunnel while keeping all saved rules and their individual enable states intact

#### Scenario: Re-enable split tunneling
- **WHEN** the user turns the split-tunneling toggle back on
- **THEN** the system resumes generating routing rules from the previously saved and enabled rules without requiring the user to re-enter them

### Requirement: Enabled split-tunnel rules apply their configured action to matching traffic in VPN mode, evaluated in order
When VPN mode is active and split tunneling is enabled, the system SHALL evaluate enabled domain and IP/CIDR rules against traffic in saved list order and route matching traffic according to the first matching rule's action (direct, proxy, or block), while traffic matching no enabled rule continues to route through the proxy.

#### Scenario: Matched domain traffic routes directly
- **WHEN** VPN mode is connected, split tunneling is enabled, and the first enabled rule matching a domain has the direct action
- **THEN** traffic destined for that domain (and its subdomains, unless the rule specifies an exact-match value) is routed directly instead of through the remote proxy server

#### Scenario: Matched domain traffic is forced through the proxy
- **WHEN** VPN mode is connected, split tunneling is enabled, and the first enabled rule matching a domain has the proxy action
- **THEN** traffic destined for that domain is routed through the remote proxy server

#### Scenario: Matched traffic is blocked
- **WHEN** VPN mode is connected, split tunneling is enabled, and the first enabled rule matching a domain or IP/CIDR has the block action
- **THEN** traffic destined for that domain or address range is blocked rather than routed through either the proxy or a direct outbound

#### Scenario: Matched IP/CIDR traffic follows its rule's action
- **WHEN** VPN mode is connected, split tunneling is enabled, and an enabled rule matches an IP or CIDR range
- **THEN** traffic destined for that address range is routed according to that rule's action

#### Scenario: Overlapping rules resolve to the first match in saved order
- **WHEN** VPN mode is connected, split tunneling is enabled, and traffic matches more than one enabled rule
- **THEN** the system applies the action of whichever matching rule appears first in the saved rule order

#### Scenario: Unmatched traffic remains proxied
- **WHEN** VPN mode is connected and split tunneling is enabled
- **THEN** traffic that matches no enabled split-tunnel rule continues to route through the remote proxy server, unchanged from current behavior

#### Scenario: Disabled rule has no effect
- **WHEN** VPN mode is connected and a saved split-tunnel rule is individually disabled
- **THEN** traffic matching that rule's value is evaluated as if the rule were absent

#### Scenario: Split tunneling has no effect in System Proxy mode
- **WHEN** the connection mode is System Proxy rather than VPN
- **THEN** saved split-tunnel rules have no effect on proxy routing

### Requirement: Split-tunnel rule changes apply to an active VPN session without a manual reconnect
The system SHALL apply changes to the enabled split-tunnel rule list or the split-tunneling toggle to an already-connected VPN session by regenerating the tunnel configuration and restarting the managed Xray process, without requiring the user to disconnect and reconnect VPN mode.

#### Scenario: Add a rule while VPN is connected
- **WHEN** the user adds and enables a new split-tunnel rule while VPN mode is already connected
- **THEN** the system regenerates the tunnel configuration and restarts the managed Xray process so the new rule takes effect without the user manually disconnecting

#### Scenario: Change rules while disconnected
- **WHEN** the user adds, edits, or removes split-tunnel rules while VPN mode is not connected
- **THEN** the system persists the changes and applies them the next time VPN mode connects, without restarting any running process

### Requirement: User can test whether a domain or IP would match a saved rule
The system SHALL provide a rule tester in the split-tunneling settings UI that, given a user-entered domain or IP value, evaluates it against the saved rule list using the same first-match-wins logic used for tunnel routing generation, and displays the result without requiring an active VPN connection.

#### Scenario: Tester shows a matching rule
- **WHEN** the user enters a domain or IP in the rule tester that matches an enabled saved rule
- **THEN** the system displays that rule's value and action as the result, without needing VPN mode to be connected

#### Scenario: Tester shows no match
- **WHEN** the user enters a domain or IP in the rule tester that matches no enabled saved rule
- **THEN** the system indicates no rule matches and that the connection's default proxy behavior would apply

#### Scenario: Tester ignores disabled rules
- **WHEN** the user enters a domain or IP that matches only a disabled saved rule
- **THEN** the system displays the result as if that rule were absent, consistent with disabled rules having no effect on tunnel routing

#### Scenario: Tester result stays consistent with generated routing behavior
- **WHEN** the rule tester evaluates a value against the saved rule list
- **THEN** the result matches what the system would generate as tunnel routing behavior for that same value and rule list
