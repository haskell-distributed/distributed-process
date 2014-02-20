
ifneq (,$(BASE_DIR))
include $(BASE_DIR)/build.mk
else
include ../build.mk
endif

