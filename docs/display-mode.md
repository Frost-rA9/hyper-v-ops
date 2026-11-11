# Display mode

## Conclusion

The display mode comes from two places. The virtual display driver publishes the available modes. Sunshine selects one of them. The client request reaches the display only when the two agree.

## Sources

The virtual display driver publishes its modes in `media/vdd_settings.xml`. Windows sees only the modes in that file.

Sunshine selects a mode with `dd_resolution_option` and `dd_refresh_rate_option` in its own configuration.

## Fault conditions

A settings file with one mode leaves Windows with one choice. The client cannot request another mode.

With `dd_resolution_option` set to `manual`, Sunshine pins the mode from its own configuration. The client request never reaches the display.

## Configuration

1. Put several resolutions in `media/vdd_settings.xml`.
2. Set `dd_resolution_option` and `dd_refresh_rate_option` to `auto`.

## How the driver reads vdd_settings.xml

- The driver takes the distinct width and height pairs as the resolution list.
- The `global` block is the refresh list for every resolution.
- The `refresh_rate` inside a `resolution` entry sets the default for that width and height pair.
