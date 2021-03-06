##
## Makefile - build lisp standalone hacks
##

# I know this is stupid and I should probably make an ASDF method.

# What implementation to make standalone programs with.
LISP ?= sbcl

PLAIN_FLAGS =
ifeq ($(LISP),sbcl)
PLAIN_FLAGS = --no-userinit
endif
ifeq ($(LISP),ccl)
PLAIN_FLAGS = --no-init
endif
ifeq ($(LISP),clisp)
PLAIN_FLAGS = -norc
endif

# Where to put executables 
INSTALL_DIR=$(HOME)/bin/A/$(ARCH)

TARGETS=lish

default: $(TARGETS)

install: $(TARGETS)
	for t in $(TARGETS) ; do \
	  $(MAKE) install_$$t ; \
	done

install_%:	%
	if [ -d $(INSTALL_DIR) ]; then \
	  mkdir -p $(INSTALL_DIR) ; \
	fi
	cp $< $(INSTALL_DIR)

clean_%:	%
	rm -i %

.PHONY:	lish
lish:
	echo "(l :tiny-repl) (l :tiny-debug) (l :lish) (lish:make-standalone)"\
	 | $(LISP) $(LISP_FLAGS) -- -norl

.PHONY:	lishfu
lishfu:
	echo "(l :tiny-repl) (l :tiny-debug) (l :lish) " \
              '(load "fully-loaded.lisp") (lish:make-standalone)' \
	 | $(LISP) $(LISP_FLAGS) -- -norl

# plain, aka without my (or your) startup

.PHONY:	lishp
lishp:
	echo "(load \"~/quicklisp/setup.lisp\") \
(push \"../\" asdf:*central-registry*) \
(push \"../opsys/\" asdf:*central-registry*) \
(push \"./\" asdf:*central-registry*) \
(asdf:load-system :lish) \
(setf asdf:*central-registry* \
 (delete \"./\" asdf:*central-registry* :test #'equal)) \
(setf asdf:*central-registry* \
 (delete \"../\" asdf:*central-registry* :test #'equal)) \
(lish:make-standalone)" \
	 | $(LISP) $(PLAIN_FLAGS) -- -norl
