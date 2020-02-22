#!/usr/bin/env python

import re

def html_headers(lines):
    result = {}
    for line in lines:
        m = re.search('^([^:]*):\s+(.*?) *$', line)
        if m:
            result[m.group(1)] = m.group(2)
    return result


class FilterModule(object):
    def filters(self):
        return {
            'html_headers': html_headers
        }

# vim: set sw=4 ts=4 indk= et:
