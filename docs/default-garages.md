# Default public garages

The core provisions 16 default public garages during startup, after existing garages, bays and
properties have loaded. Each managed location has one bay. Missing bays are restored, the nearest
existing bay keeps its ID, and surplus bays at managed locations are removed.

The locations are defined in `server/default_garages.lua`: Public Garage, Motel Parking, Casino
Parking, San Andreas Parking, Spanish Avenue Parking, Caesars 24 North and West, Laguna, LSIA,
Vespucci Beach, Motor Hotel, Route 68 Liquor, Sandy Shores, Paleto Bay, Pillbox and Grapeseed.

## Existing servers

Keep the resource name `whip_core` and preserve your server's `config.lua`. Remove the old
`ensure whip_garages` entry before starting this version. Existing locations owned by that add-on
are adopted by the core without changing their garage keys or moving stored vehicle records.

The setup skips a missing default when a public garage already exists within 25 metres of its
marker or bay, or a private garage is within 8 metres. Existing custom/private garages are not
managed. The original stock `legion_square` garage at its stock position is treated as a default.
Edits to a managed default's bays are reconciled at the next restart; edit the definitions when
changing those locations permanently. Back up the database before upgrading an existing server.

## Validation

Run `lua5.4 dev/garage_defaults_test.lua` from the repository root for the offline regression
checks. These use the production garage setup and bay reconciliation with
stubbed database/native boundaries. They do not replace an FXServer integration test.

In a test server, verify first startup and restart, adoption from `whip_garages`, an existing custom
garage near a default, and normal vehicle storage/retrieval.

Default garage locations integrated into WHIP Core. WHIP's original licenses and notices are retained.
