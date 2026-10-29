// -*- mode: c++; tab-width: 4; indent-tabs-mode: t; eval: (progn (c-set-style "stroustrup") (c-set-offset 'innamespace 0)); -*-
// vi:set ts=4 sts=4 sw=4 noet :
//
// Copyright 2010-2020 wkhtmltopdf authors
//
// This file is part of wkhtmltopdf.
//
// wkhtmltopdf is free software: you can redistribute it and/or modify
// it under the terms of the GNU Lesser General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// wkhtmltopdf is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU Lesser General Public License
// along with wkhtmltopdf.  If not, see <http://www.gnu.org/licenses/>.

#include "imagecommandlineparser.hh"
#include "progressfeedback.hh"
#include <QApplication>
#include <QWebFrame>
#include <imageconverter.hh>
#include <imagesettings.hh>
#include <utilities.hh>

#if defined(Q_OS_UNIX)
#include <locale.h>
#endif
// Embedded component manifest — same wording as the Windows VS_VERSION_INFO
// FileDescription (src/image/wkhtmltoimage_resource.rc), so macOS Mach-O
// builds carry the identical, factual component-version declaration Windows
// PE builds expose through their version resource. See the comment in
// src/pdf/wkhtmltopdf.cc for background.
#if defined(Q_CC_GNU)
static const char wkhtmltoimage_component_manifest[] __attribute__((used)) =
#else
static const char wkhtmltoimage_component_manifest[] =
#endif
"wkhtmltoimage 0.12.6 components: Qt 4.8.7 (CVE-hardened fork); "
    "zlib 1.3.2-patched (CVE-2026-85091 fixed, commit df84af25); "
    "SQLite 3.54.1; libpng 1.6.58; libjpeg-turbo 3.1.4.1";

int main(int argc, char** argv) {
#if defined(Q_OS_UNIX)
	setlocale(LC_ALL, "");
#if QT_VERSION >= 0x050000 && !defined(__EXTENSIVE_WKHTMLTOPDF_QT_HACK__)
	setenv("QT_QPA_PLATFORM", "offscreen", 0);
#endif
#endif
	//This will store all our settings
	wkhtmltopdf::settings::ImageGlobal settings;
	//Create a command line parser to parse commandline arguments
	ImageCommandLineParser parser(settings);
	//Parse the arguments
	parser.parseArguments(argc, (const char**)argv);


	bool use_graphics=true;
#if defined(Q_OS_UNIX) || defined(Q_OS_MAC)
#ifdef __EXTENSIVE_WKHTMLTOPDF_QT_HACK__
	use_graphics=settings.useGraphics;
	if (!use_graphics) QApplication::setGraphicsSystem("raster");
#endif
#endif
	QApplication a(argc, argv, use_graphics);
	MyLooksStyle * style = new MyLooksStyle();
	a.setStyle(style);

	//Create the actual page converter to convert the pages
	wkhtmltopdf::ImageConverter converter(settings);
	QObject::connect(&converter, SIGNAL(checkboxSvgChanged(const QString &)), style, SLOT(setCheckboxSvg(const QString &)));
	QObject::connect(&converter, SIGNAL(checkboxCheckedSvgChanged(const QString &)), style, SLOT(setCheckboxCheckedSvg(const QString &)));
	QObject::connect(&converter, SIGNAL(radiobuttonSvgChanged(const QString &)), style, SLOT(setRadioButtonSvg(const QString &)));
	QObject::connect(&converter, SIGNAL(radiobuttonCheckedSvgChanged(const QString &)), style, SLOT(setRadioButtonCheckedSvg(const QString &)));

	wkhtmltopdf::ProgressFeedback feedback(settings.logLevel, converter);
	bool success = converter.convert();
	return handleError(success, converter.httpErrorCode());
}
