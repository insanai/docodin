"""Command-line and common processing for Docutils front-end tools.

Runtime settings come from component ``settings_spec`` definitions, optional
configuration files and command-line options (`OptionParser`); use
`get_default_settings` for programmatic defaults.
"""

from __future__ import annotations

import codecs
import configparser
import optparse
import os
import os.path
import sys
import warnings
from collections.abc import Iterable, Mapping
from optparse import SUPPRESS_HELP  # noqa: F401 - part of the docutils.frontend namespace
from pathlib import Path
from typing import Any, ClassVar

import docutils
from docutils import io, utils

__docformat__ = "reStructuredText"


def store_multiple(option: optparse.Option, opt: str, value: Any, parser: OptionParser,
                   *args: str, **kwargs: Any) -> None:
    """Store multiple values in `parser.values` (option callback)."""
    for attribute in args:
        setattr(parser.values, attribute, None)
    for key, item in kwargs.items():
        setattr(parser.values, key, item)


def read_config_file(option: optparse.Option, opt: str, value: Any, parser: OptionParser) -> None:
    """Read a configuration file during option processing (option callback)."""
    try:
        new_settings = parser.get_config_file_settings(value)
    except ValueError as err:
        parser.error(err)
    parser.values.update(new_settings, parser)


def validate_encoding(setting: str, value: str | None = None, option_parser: Any = None,
                      config_parser: Any = None, config_section: str | None = None) -> str | None:
    if value is None:
        value = setting
    if value == "":
        warnings.warn('Input encoding detection will be removed and the special encoding values '
                      'None and "" become invalid in Docutils 1.0.', FutureWarning, stacklevel=2)
        return None
    try:
        codecs.lookup(value)
    except LookupError:
        prefix = f'setting "{setting}":' if setting else ""
        raise LookupError(f'{prefix} unknown encoding: "{value}"') from None
    return value


def validate_encoding_error_handler(setting: str, value: str | None = None,
                                    option_parser: Any = None, config_parser: Any = None,
                                    config_section: str | None = None) -> str:
    if value is None:
        value = setting
    try:
        codecs.lookup_error(value)
    except LookupError:
        raise LookupError('unknown encoding error handler: "%s" (choices: "strict", "ignore", '
                          '"replace", "backslashreplace", "xmlcharrefreplace", and possibly '
                          "others; see documentation for the Python ``codecs`` module)"
                          % value) from None
    return value


def validate_encoding_and_error_handler(setting: str, value: str | None = None,
                                        option_parser: Any = None, config_parser: Any = None,
                                        config_section: str | None = None) -> str | None:
    """Validate "<encoding>[:<error handler>]" and set the error handler setting."""
    if ":" in value:
        encoding, handler = value.split(":")
        validate_encoding_error_handler(handler)
        if config_parser:
            config_parser.set(config_section, setting + "_error_handler", handler)
        else:
            setattr(option_parser.values, setting + "_error_handler", handler)
    else:
        encoding = value
    return validate_encoding(encoding)


def validate_boolean(setting: str | bool, value: str | None = None, option_parser: Any = None,
                     config_parser: Any = None, config_section: str | None = None) -> bool:
    if value is None:
        value = setting
    if isinstance(value, bool):
        return value
    try:
        return OptionParser.booleans[value.strip().lower()]
    except KeyError:
        raise LookupError('unknown boolean value: "%s"' % value) from None


def validate_ternary(setting: str | bool, value: str | None = None, option_parser: Any = None,
                     config_parser: Any = None, config_section: str | None = None) -> Any:
    if value is None:
        value = setting
    if isinstance(value, bool) or value is None:
        return value
    try:
        return OptionParser.booleans[value.strip().lower()]
    except KeyError:
        return value


def validate_nonnegative_int(setting: str | int, value: str | None = None,
                             option_parser: Any = None, config_parser: Any = None,
                             config_section: str | None = None) -> int:
    if value is None:
        value = setting
    value = int(value)
    if value < 0:
        raise ValueError("negative value; must be positive or zero")
    return value


def validate_threshold(setting: str | int, value: str | None = None, option_parser: Any = None,
                       config_parser: Any = None, config_section: str | None = None) -> int:
    if value is None:
        value = setting
    try:
        return int(value)
    except ValueError:
        try:
            return OptionParser.thresholds[value.lower()]
        except (KeyError, AttributeError):
            raise LookupError("unknown threshold: %r." % value) from None


def validate_colon_separated_string_list(setting: str | list[str], value: str | None = None,
                                         option_parser: Any = None, config_parser: Any = None,
                                         config_section: str | None = None) -> list[str]:
    if value is None:
        value = setting
    if not isinstance(value, list):
        return value.split(":")
    last = value.pop()
    value.extend(last.split(":"))
    return value


def validate_comma_separated_list(setting: str | list[str], value: str | None = None,
                                  option_parser: Any = None, config_parser: Any = None,
                                  config_section: str | None = None) -> list[str]:
    """Split the last item at commas (strip whitespace, drop empty items)."""
    if value is None:
        value = setting
    if not isinstance(value, list):
        value = [value]
    last = value.pop()
    value.extend(item.strip(" \t\n") for item in last.split(",") if item.strip(" \t\n"))
    return value


def validate_math_output(setting: str, value: str | None = None, option_parser: Any = None,
                         config_parser: Any = None,
                         config_section: str | None = None) -> tuple[str, str] | tuple[()]:
    """Parse "<format> [<options>]"; check format and MathML converter."""
    if value is None:
        value = setting
    formats = ("html", "latex", "mathml", "mathjax")
    tex2mathml_converters = ("", "latexml", "ttm", "blahtexml", "pandoc")
    if not value:
        return ()
    values = value.split(maxsplit=1)
    format = values[0].lower()
    options = values[1] if len(values) > 1 else ""
    if format not in formats:
        raise LookupError(f'Unknown math output format: "{value}",\n    choose from {formats}.')
    if format == "mathml":
        converter = options.lower()
        if converter not in tex2mathml_converters:
            raise LookupError(f'MathML converter "{options}" not supported,\n'
                              f"    choose from {tex2mathml_converters}.")
        options = converter
    return format, options


def validate_url_trailing_slash(setting: str | None, value: str | None = None,
                                option_parser: Any = None, config_parser: Any = None,
                                config_section: str | None = None) -> str:
    if value is None:
        value = setting
    if not value:
        return "./"
    return value if value.endswith("/") else value + "/"


def validate_dependency_file(setting: str | None, value: str | None = None,
                             option_parser: Any = None, config_parser: Any = None,
                             config_section: str | None = None) -> utils.DependencyList:
    if value is None:
        value = setting
    try:
        return utils.DependencyList(value)
    except OSError:
        return utils.DependencyList(None)


def validate_strip_class(setting: str, value: str | None = None, option_parser: Any = None,
                         config_parser: Any = None,
                         config_section: str | None = None) -> list[str]:
    if value is None:
        value = setting
    value = validate_comma_separated_list(value)
    for cls in value:
        normalized = docutils.nodes.make_id(cls)
        if cls != normalized:
            raise ValueError("Invalid class value %r (perhaps %r?)" % (cls, normalized))
    return value


def validate_smartquotes_locales(setting: Any, value: Any = None, option_parser: Any = None,
                                 config_parser: Any = None,
                                 config_section: str | None = None) -> list:
    """Parse "<language>:<quotes>" items (4 quote characters, or 4 ':'-separated)."""
    if value is None:
        value = setting
    lc_quotes: list = []
    for item in validate_comma_separated_list(value):
        try:
            lang, quotes = item.split(":", 1)
        except AttributeError:
            lc_quotes.append(item)
            continue
        except ValueError:
            raise ValueError('Invalid value "%s". Format is "<language>:<quotes>".'
                             % item.encode("ascii", "backslashreplace")) from None
        quotes = quotes.strip()
        multichar_quotes = quotes.split(":")
        if len(multichar_quotes) == 4:
            quotes = multichar_quotes
        elif len(quotes) != 4:
            raise ValueError('Invalid value "%s". Please specify 4 quotes\n'
                             "    (primary open/close; secondary open/close)."
                             % item.encode("ascii", "backslashreplace"))
        lc_quotes.append((lang, quotes))
    return lc_quotes


def make_paths_absolute(pathdict: dict[str, Any], keys: Iterable[str],
                        base_path: str | Path | None = None) -> None:
    """Interpret the path settings `keys` of `pathdict` relative to `base_path`."""
    base_path = Path.cwd() if base_path is None else Path(base_path)
    for key in keys:
        if key in pathdict:
            value = pathdict[key]
            if isinstance(value, (list, tuple)):
                value = [str((base_path / path).resolve()) for path in value]
            elif value:
                value = str((base_path / value).resolve())
            pathdict[key] = value


def make_one_path_absolute(base_path: str, path: str) -> str:
    warnings.warn("frontend.make_one_path_absolute() will be removed in Docutils 2.0 or later.",
                  DeprecationWarning, stacklevel=2)
    return os.path.abspath(os.path.join(base_path, path))


def filter_settings_spec(settings_spec: tuple, *exclude: str, **replace: tuple) -> tuple:
    """Return a copy of `settings_spec` excluding/replacing some settings."""
    settings = list(settings_spec)
    for i in range(2, len(settings), 3):
        newopts = []
        for opt_spec in settings[i]:
            opt_name = [opt_string[2:].replace("-", "_") for opt_string in opt_spec[1]
                        if opt_string.startswith("--")][0]
            if opt_name in exclude:
                continue
            newopts.append(replace.get(opt_name, opt_spec))
        settings[i] = tuple(newopts)
    return tuple(settings)


class Values(optparse.Values):
    """Storage for option values (runtime settings)."""

    def __init__(self, defaults: dict[str, Any] | None = None) -> None:
        warnings.warn("frontend.Values class will be removed in Docutils 2.0 or later.",
                      DeprecationWarning, stacklevel=2)
        super().__init__(defaults=defaults)
        if getattr(self, "record_dependencies", None) is None:
            self.record_dependencies = utils.DependencyList()

    def update(self, other_dict: Values | Mapping[str, Any], option_parser: Any) -> None:
        """Update settings; list settings are extended, not replaced."""
        if isinstance(other_dict, Values):
            other_dict = other_dict.__dict__
        other_dict = dict(other_dict)
        for setting in option_parser.lists:
            if hasattr(self, setting) and setting in other_dict:
                value = getattr(self, setting)
                if value:
                    value += other_dict[setting]
                    del other_dict[setting]
        self._update_loose(other_dict)

    def copy(self) -> Values:
        with warnings.catch_warnings():
            warnings.filterwarnings("ignore", category=DeprecationWarning)
            return self.__class__(defaults=self.__dict__)

    def setdefault(self, name: str, default: Any) -> Any:
        if getattr(self, name, None) is None:
            setattr(self, name, default)
        return getattr(self, name)


class Option(optparse.Option):
    """`optparse.Option` with a `validator` and an `overrides` attribute."""

    ATTRS = optparse.Option.ATTRS + ["validator", "overrides"]

    def __init__(self, *args: str | None, **kwargs: Any) -> None:
        warnings.warn("The frontend.Option class will be removed in Docutils 2.0 or later.",
                      DeprecationWarning, stacklevel=2)
        super().__init__(*args, **kwargs)

    def process(self, opt: str, value: Any, values: Values, parser: OptionParser) -> int:
        result = super().process(opt, value, values, parser)
        setting = self.dest
        if setting:
            if self.validator:
                value = getattr(values, setting)
                try:
                    new_value = self.validator(setting, value, parser)
                except Exception as err:  # noqa: BLE001 - reported as option error
                    raise optparse.OptionValueError('Error in option "%s":\n    %s'
                                                    % (opt, io.error_string(err))) from None
                setattr(values, setting, new_value)
            if self.overrides:
                setattr(values, self.overrides, None)
        return result


def _general_options(default_error_encoding: str) -> tuple:
    """Option specifications of the "General Docutils Options" group."""
    from docutils._settings import general_options

    return general_options(default_error_encoding, store_multiple, read_config_file)


class OptionParser(optparse.OptionParser, docutils.SettingsSpec):
    """Settings parser for command-line and library use."""

    standard_config_files: ClassVar[list[str]] = [
        "/etc/docutils.conf", "./docutils.conf", "~/.docutils"]
    threshold_choices = ("info", "1", "warning", "2", "error", "3", "severe", "4", "none", "5")
    thresholds = {"info": 1, "warning": 2, "error": 3, "severe": 4, "none": 5}
    booleans = {"1": True, "on": True, "yes": True, "true": True, "0": False, "off": False,
                "no": False, "false": False, "": False}
    default_error_encoding = (getattr(sys.stderr, "encoding", None) or io._locale_encoding
                              or "ascii")
    default_error_encoding_error_handler = "backslashreplace"
    settings_spec = ("General Docutils Options", None, _general_options(default_error_encoding))
    settings_defaults = {"_disable_config": None, "_source": None, "_destination": None,
                         "_config_files": None}
    relative_path_settings: tuple[str, ...] = ()
    config_section = "general"
    version_template = "%%prog (Docutils %s%s, Python %s, on %s)" % (
        docutils.__version__,
        docutils.__version_details__ and f" [{docutils.__version_details__}]" or "",
        sys.version.split()[0], sys.platform)

    def __init__(self, components: Iterable[Any] = (), defaults: Mapping[str, Any] | None = None,
                 read_config_files: bool | None = False, *args: Any, **kwargs: Any) -> None:
        self.lists: dict[str, bool] = {}
        self.config_files: list[str] = []
        self.relative_path_settings = ("warning_stream",)
        warnings.warn("The frontend.OptionParser class will be replaced by a subclass of "
                      "argparse.ArgumentParser in Docutils 2.0 or later.\n  To get default "
                      "settings, use frontend.get_default_settings().",
                      DeprecationWarning, stacklevel=2)
        super().__init__(*args, option_class=Option, add_help_option=False,
                         formatter=optparse.TitledHelpFormatter(width=78), **kwargs)
        if not self.version:
            self.version = self.version_template
        self.components = (self, *components)
        self.populate_from_components(self.components)
        self.defaults.update(defaults or {})
        if read_config_files and not self.defaults["_disable_config"]:
            try:
                config_settings = self.get_standard_config_settings()
            except ValueError as err:
                self.error(str(err))
            self.defaults.update(config_settings.__dict__)

    def populate_from_components(self, components: Iterable[Any]) -> None:
        """Add the options of each component's `settings_spec`."""
        for component in components:
            if component is None:
                continue
            settings_spec = component.settings_spec
            self.relative_path_settings += component.relative_path_settings
            for i in range(0, len(settings_spec), 3):
                self._add_option_group(*settings_spec[i:i + 3])
                if component.settings_defaults:
                    self.defaults.update(component.settings_defaults)
        for component in components:
            if component and component.settings_default_overrides:
                self.defaults.update(component.settings_default_overrides)

    def _add_option_group(self, title: str | None, description: str | None,
                          option_spec: Iterable[tuple]) -> None:
        if title:
            group: Any = optparse.OptionGroup(self, title, description)
            self.add_option_group(group)
        else:
            group = self
        for help_text, option_strings, kwargs in option_spec:
            option = group.add_option(*option_strings, help=help_text, **kwargs)
            if kwargs.get("action") == "append":
                self.lists[option.dest] = True

    @classmethod
    def get_standard_config_files(cls) -> list[str]:
        """Standard config files (or those listed in $DOCUTILSCONFIG)."""
        if "DOCUTILSCONFIG" in os.environ:
            config_files = os.environ["DOCUTILSCONFIG"].split(os.pathsep)
        else:
            config_files = cls.standard_config_files
        return [os.path.expanduser(f) for f in config_files if f.strip()]

    def get_standard_config_settings(self) -> Values:
        with warnings.catch_warnings():
            warnings.filterwarnings("ignore", category=DeprecationWarning)
            settings = Values()
        for filename in self.get_standard_config_files():
            settings.update(self.get_config_file_settings(filename), self)
        return settings

    def get_config_file_settings(self, config_file: str) -> dict[str, Any]:
        """Settings of the component sections of `config_file`."""
        config_parser = ConfigParser()
        applied: set[str | None] = set()
        with warnings.catch_warnings():
            warnings.filterwarnings("ignore", category=DeprecationWarning)
            self.config_files += config_parser.read(config_file, self)
            settings = Values()
        for component in self.components:
            if not component:
                continue
            sections = (*(component.config_section_dependencies or ()), component.config_section)
            for section in sections:
                if section in applied:
                    continue
                applied.add(section)
                if config_parser.has_section(section):
                    settings.update(config_parser[section], self)
        make_paths_absolute(settings.__dict__, self.relative_path_settings,
                            os.path.dirname(config_file))
        return settings.__dict__

    def check_values(self, values: Values, args: list[str]) -> Values:
        """Store positional arguments and make path settings absolute."""
        values._source, values._destination = self.check_args(args)
        make_paths_absolute(values.__dict__, self.relative_path_settings)
        values._config_files = self.config_files
        return values

    def check_args(self, args: list[str]) -> tuple[str | None, str | None]:
        source = destination = None
        if args:
            source = args.pop(0)
            if source == "-":
                source = None
        if args:
            destination = args.pop(0)
            if destination == "-":
                destination = None
        if args:
            self.error("Maximum 2 arguments allowed.")
        if source and source == destination:
            self.error("Do not specify the same file for both source and destination.  "
                       "It will clobber the source file.")
        return source, destination

    def get_default_values(self) -> Values:
        with warnings.catch_warnings():
            warnings.filterwarnings("ignore", category=DeprecationWarning)
            defaults = Values(self.defaults)
        defaults._config_files = self.config_files
        return defaults

    def get_option_by_dest(self, dest: str) -> Option:
        for group in [*self.option_groups, self]:
            for option in group.option_list:
                if option.dest == dest:
                    return option
        raise KeyError("No option with dest == %r." % dest)


class ConfigParser(configparser.RawConfigParser):
    """Parser for Docutils configuration files."""

    old_settings = {
        "pep_stylesheet": ("pep_html writer", "stylesheet"),
        "pep_stylesheet_path": ("pep_html writer", "stylesheet_path"),
        "pep_template": ("pep_html writer", "template"),
    }
    old_warning = ('The "[option]" section is deprecated.\nSupport for old-format configuration '
                   "files will be removed in Docutils\xa02.0.  Please revise your configuration "
                   "files.  See <https://docutils.sourceforge.io/docs/user/config.html>, section "
                   '"Old-Format Configuration Files".')
    not_utf8_error = ('Unable to read configuration file "%s": content not encoded as UTF-8.\n'
                      'Skipping "%s" configuration file.\n')

    def read(self, filenames: str | Iterable[str],  # type: ignore[override]
             option_parser: OptionParser | None = None) -> list[str]:
        if option_parser is not None:
            warnings.warn('frontend.ConfigParser.read(): parameter "option_parser" will be '
                          "removed in Docutils 2.0 or later.", DeprecationWarning, stacklevel=2)
        read_ok: list[str] = []
        if isinstance(filenames, str):
            filenames = [filenames]
        for filename in filenames:
            try:
                read_ok += super().read(filename, encoding="utf-8")
            except UnicodeDecodeError:
                sys.stderr.write(self.not_utf8_error % (filename, filename))
                continue
            if "options" in self:
                self.handle_old_config(filename)
            if option_parser is not None:
                self.validate_settings(filename, option_parser)
        return read_ok

    def handle_old_config(self, filename: str) -> None:
        """Move the settings of an "[options]" section to their new sections."""
        warnings.warn_explicit(self.old_warning, ConfigDeprecationWarning, filename, 0)
        options = dict(self["options"]) if "options" in self else {}
        if not self.has_section("general"):
            self.add_section("general")
        for key, value in options.items():
            section, setting = self.old_settings.get(key, ("general", key))
            if not self.has_section(section):
                self.add_section(section)
            if not self.has_option(section, setting):
                self.set(section, setting, value)
        self.remove_section("options")

    def validate_settings(self, filename: str, option_parser: OptionParser) -> None:
        """Call the validator function of each setting in the file."""
        for section in self.sections():
            for setting in self.options(section):
                try:
                    option = option_parser.get_option_by_dest(setting)
                except KeyError:
                    continue
                if option.validator:
                    self._validate(filename, section, setting, option, option_parser)
                if option.overrides:
                    self.set(section, option.overrides, None)

    def _validate(self, filename: str, section: str, setting: str, option: Option,
                  option_parser: OptionParser) -> None:
        value = self.get(section, setting)
        try:
            new_value = option.validator(setting, value, option_parser, config_parser=self,
                                         config_section=section)
        except Exception as err:  # noqa: BLE001 - reported with the file context
            raise ValueError(f'Error in config file "{filename}", section "[{section}]":\n'
                             f"    {io.error_string(err)}\n        {setting} = {value}") from None
        self.set(section, setting, new_value)

    def optionxform(self, optionstr: str) -> str:
        """Lowercase and transform "-" to "_"."""
        return optionstr.lower().replace("-", "_")


class ConfigDeprecationWarning(FutureWarning):
    """Warning for deprecated configuration file features."""


def get_default_settings(*components: Any) -> Values:
    """Default runtime settings for `components` (no config files, no arguments)."""
    with warnings.catch_warnings():
        warnings.filterwarnings("ignore", category=DeprecationWarning)
        return OptionParser(components).get_default_values()

