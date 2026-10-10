"""Make an old UE 4.27 source drop's Setup.bat work again without changing its dependency versions.

Epic re-hosted the dependency packs; old Commit.gitdeps.xml files point at packs that now return 403. A newer
manifest (here: Oculus-VR/UnrealEngine branch 4.27-gitdeps-fix) points at the re-hosted packs, but it also
lists later 4.27 versions of some files. This merges the two:
  - files: the old manifest's list (exact versions), wherever the new packs still contain that content;
  - files whose content isn't hosted any more: the new manifest's version of the same file if it has one
    (localization, a few media DLLs), otherwise dropped (only CI configs, test .yaml and helper .ps1 files);
  - blobs and packs: the new manifest's (the working host).

usage: python tools/merge_gitdeps.py <old Commit.gitdeps.xml> <new Commit.gitdeps.xml> <out>
"""
import sys
import xml.etree.ElementTree as ET


def main(old_p, new_p, out_p):
    old, new = ET.parse(old_p).getroot(), ET.parse(new_p).getroot()
    new_files = {f.get('Name'): f for f in new.find('Files')}
    hosted = {b.get('Hash') for b in new.find('Blobs')}
    kept = substituted = dropped = 0
    files = ET.Element('Files')
    for f in old.find('Files'):
        if f.get('Hash') in hosted:
            files.append(f)
            kept += 1
        elif f.get('Name') in new_files:
            files.append(new_files[f.get('Name')])
            substituted += 1
        else:
            dropped += 1
            print('  dropped (not hosted any more):', f.get('Name'))
    root = ET.Element('DependencyManifest', {'BaseUrl': new.get('BaseUrl')})
    root.append(files)
    root.append(new.find('Blobs'))
    root.append(new.find('Packs'))
    ET.ElementTree(root).write(out_p, encoding='utf-8', xml_declaration=True)
    print(f'files: {kept} exact, {substituted} newer version, {dropped} dropped -> {out_p}')


if __name__ == '__main__':
    main(*sys.argv[1:4])
