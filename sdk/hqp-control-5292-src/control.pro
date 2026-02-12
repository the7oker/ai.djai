VERSION = 3.12.0

TARGET = hqp5-control
TEMPLATE = app
QT -= gui
QT += core network
CONFIG += console
CONFIG += embed_manifest_exe

win32 {
	LIBS += user32.lib

	INCLUDEPATH += C:/common/include/botan-2

	CONFIG(release, debug|release) {
		LIBS += C:/common/lib/botan.lib
	} else {
		LIBS += C:/common/lib/botand.lib
	}
}

unix:!macx {
	CONFIG += link_pkgconfig
	PKGCONFIG += botan-2
}

macx {
	INCLUDEPATH += /usr/local/include/botan-2
	LIBS += -L/usr/local/lib -lbotan-2
	QMAKE_MACOSX_DEPLOYMENT_TARGET = 12.00
}

HEADERS += \
	ControlApplication.hpp \
	ControlInterface.hpp
SOURCES += \
	ControlApplication.cpp \
	ControlInterface.cpp \
	Main.cpp

