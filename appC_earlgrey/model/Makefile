# Top-level Makefile -- builds and runs every sub-example.

SUBDIRS = ip/uart ip/aon_timer ip/alert_handler soc

all: $(addsuffix .sim,$(SUBDIRS)) earlgrey

%.sim:
	$(MAKE) -C $* sim

%.lint:
	$(MAKE) -C $* lint

# The Earlgrey-faithful chip-level test uses its own Makefile because it
# pulls in 16 IPs and a longer source list.
earlgrey:
	$(MAKE) -C soc -f Makefile.earlgrey sim

earlgrey.lint:
	$(MAKE) -C soc -f Makefile.earlgrey lint

lint: $(addsuffix .lint,$(SUBDIRS)) earlgrey.lint

clean:
	for d in $(SUBDIRS); do $(MAKE) -C $$d clean; done
	$(MAKE) -C soc -f Makefile.earlgrey clean

.PHONY: all clean lint earlgrey earlgrey.lint $(addsuffix .sim,$(SUBDIRS)) $(addsuffix .lint,$(SUBDIRS))
