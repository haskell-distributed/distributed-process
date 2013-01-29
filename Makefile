
NAME ?= ''
FNAME = $(shell echo $(NAME) | tr A-Z a-z)
ROOT_DIRECTORY=.
TEMPLATE_DIR=${ROOT_DIRECTORY}/static/templates
TEMPLATE_FILES=$(wildcard ${TEMPLATE_DIR}/*)
TEMPLATES=$(basename $(notdir ${TEMPLATE_FILES}))

all:
	$(info select a target)
	$(info ${TEMPLATES})

ifneq ($(NAME), '')
$(TEMPLATES):
	cat ${TEMPLATE_DIR}/$@.md | sed s/@PAGE@/${NAME}/g >> ${ROOT_DIRECTORY}/wiki/${FNAME}.md
else
$(TEMPLATES):
	$(error you need to specify NAME=<name> to run this target)
endif
