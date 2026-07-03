# Top-level dv Makefile.
#
# Two flavours of real-RTL dv:
#
#   chip/     --  full chip_earlgrey_verilator (compile-validated; sim
#                 throughput is hours per simulated us at chip scale, so
#                 the practical demonstration of end-to-end stimulus +
#                 observation is ip_uart/).
#   ip_uart/  --  single-IP real-RTL UART, driven through the actor
#                 framework's symbolic-name RAL.

.PHONY: all chip ip_uart lint clean

all: ip_uart

chip:
	$(MAKE) -C chip

ip_uart:
	$(MAKE) -C ip_uart

lint:
	$(MAKE) -C chip lint
	$(MAKE) -C ip_uart lint

clean:
	$(MAKE) -C chip clean
	$(MAKE) -C ip_uart clean
